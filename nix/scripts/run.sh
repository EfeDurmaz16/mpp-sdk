#!/usr/bin/env bash
set -euo pipefail

kind="${1:?check kind is required}"
lane="${2:?check lane is required}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
test -f nix/interop-cases.json
export CI=1 GOTOOLCHAIN=local GOWORK=off
# pnpm 11 otherwise reinstalls after moving a prepared workspace, replacing
# the native addon patches supplied by Nix. Dependency builds are explicit.
export pnpm_config_verify_deps_before_run=false
export NIX_EXPERIMENT_ROOT="$root"
result_dir="$root/.nix-results/$kind-$lane${NIX_TYPESCRIPT_GATE:+-$NIX_TYPESCRIPT_GATE}"
mkdir -p "$result_dir"
started="$(date +%s)"
finish() {
  local status=$?
  trap - EXIT
  python3 - "$result_dir/result.json" "$kind" "$lane" "$started" "$status" <<'PY'
import json, pathlib, sys, time
path, kind, lane, start, status = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "kind": kind, "lane": lane, "exit_code": int(status),
    "duration_seconds": time.time() - int(start),
}, indent=2) + "\n")
PY
  exit "$status"
}
trap finish EXIT

build() {
  local target="$1" output before after
  before="$(date +%s)"
  output="$(python3 nix/scripts/measure.py command --results "$result_dir/phases.jsonl" --label "realize-$target" -- nix build --no-update-lock-file --no-link --print-out-paths ".#$target")"
  after="$(date +%s)"
  python3 - "$result_dir/builds.jsonl" "$target" "$output" "$before" "$after" <<'PY'
import json, sys
path, target, output, start, end = sys.argv[1:]
with open(path, "a") as f:
    f.write(json.dumps({"target": target, "output": output,
                       "seconds": int(end)-int(start)}) + "\n")
PY
  printf '%s\n' "$output"
}

stage() {
  local output
  output="$(build "$1")"
  # chmod only the imported tree before merging it into the checkout. Never
  # traverse all existing dependencies again for each generated-asset stage.
  python3 nix/scripts/measure.py command --results "$result_dir/phases.jsonl" \
    --label "stage-$1" -- python3 - "$output" "$root" <<'PYTHON'
from pathlib import Path
import os, shutil, stat, sys
source, root = map(Path, sys.argv[1:])
for directory, subdirs, files in os.walk(source, followlinks=False):
    relative = Path(directory).relative_to(source)
    destination = root / relative
    destination.mkdir(parents=True, exist_ok=True)
    for name in [*subdirs, *files]:
        artifact = Path(directory) / name
        target = destination / name
        if artifact.is_symlink():
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.exists():
                raise RuntimeError(f"Cannot replace directory with link: {target}")
            target.symlink_to(os.readlink(artifact))
        elif artifact.is_file():
            if target.is_symlink():
                target.unlink()
            shutil.copyfile(artifact, target)
            target.chmod(stat.S_IMODE(artifact.stat().st_mode) | stat.S_IWUSR)
PYTHON
}

prepare_harness() {
  stage html-assets
  stage typescript-sdk
  stage harness-deps
  (cd harness && python3 "$root/nix/scripts/measure.py" command --results "$result_dir/phases.jsonl" --label harness-typecheck -- ./node_modules/.bin/tsc --noEmit)
}

prepare_adapters() {
  local rust_path go_client='' go_server='' swift_path=''
  rust_path="$(build rust-harness)"
  if [[ "$lane" == go ]]; then
    go_client="$(build go-client)"
    go_server="$(build go-server)"
  fi
  if [[ "$lane" == swift ]]; then
    swift_path="$(build swift-harness)"
    PAY_KIT_CONFORMANCE_COMMANDS="$(python3 - "$swift_path" <<'PYTHON'
import json, sys
print(json.dumps({"swift": [sys.argv[1] + "/bin/mpp-conformance"]}))
PYTHON
)"
    export PAY_KIT_CONFORMANCE_COMMANDS
  fi
  PAY_KIT_HARNESS_COMMANDS="$(python3 - "$rust_path" "$go_client" "$go_server" "$swift_path" <<'PY'
import json, sys
rust, client, server, swift = sys.argv[1:]
commands = {}
for role in ("client", "server"):
    for adapter, binary in (("rust", "mpp_harness"),
                            ("rust-x402", "x402_harness"),
                            ("rust-x402-upto", "x402_harness_upto")):
        commands[f"{role}:{adapter}"] = [f"{rust}/bin/{binary}_{role}"]
if client:
    for adapter in ("go", "go-x402", "go-x402-upto"):
        commands[f"client:{adapter}"] = [f"{client}/bin/paykit-go-client"]
if server:
    for adapter in ("go", "go-x402-upto"):
        commands[f"server:{adapter}"] = [f"{server}/bin/paykit-go-server"]
if swift:
    for adapter, binary in (("swift", "SwiftHarnessClient"),
                            ("swift-x402", "SwiftX402Client"),
                            ("swift-x402-upto", "SwiftX402UptoClient")):
        commands[f"client:{adapter}"] = [f"{swift}/bin/{binary}"]
print(json.dumps(commands))
PY
)"
  export PAY_KIT_HARNESS_COMMANDS
}

case "$kind" in
  unit)
    case "$lane" in
      typescript)
        stage html-assets
        stage typescript-unit
        bash nix/scripts/sdk.sh "$lane"
        ;;
      audit) stage typescript-audit; bash nix/scripts/sdk.sh "$lane" ;;
      html) stage html-assets; bash nix/scripts/sdk.sh "$lane" ;;
      rust)
        stage html-assets
        bash nix/scripts/sdk.sh "$lane"
        ;;
      go) bash nix/scripts/sdk.sh "$lane" ;;
      python|ruby|lua|php|kotlin|swift) bash nix/scripts/languages.sh "$lane" ;;
      *) printf 'Unknown unit lane: %s\n' "$lane" >&2; exit 2 ;;
    esac
    ;;
  interop)
    prepare_harness
    if [[ "$lane" == typescript ]]; then
      (cd harness && ./node_modules/.bin/vitest run \
        test/adapter-command.test.ts test/process.test.ts test/adapter-identity.test.ts)
    fi
    if [[ "$lane" != onchain ]]; then prepare_adapters; fi
    case "$lane" in
      go|python|swift|kotlin)
        if [[ -z "${PAYMENT_CHANNELS_PROGRAM_SO:-}" ]]; then
          if [[ "$(uname -s)" == Darwin ]]; then
            echo 'Provide the Linux producer SBF artifact in PAYMENT_CHANNELS_PROGRAM_SO.' >&2
            exit 1
          fi
          PAYMENT_CHANNELS_PROGRAM_SO="$(build payment-channels)/lib/payment_channels.so"
          export PAYMENT_CHANNELS_PROGRAM_SO
        fi
        test -s "$PAYMENT_CHANNELS_PROGRAM_SO"
        ;;
    esac
    case "$lane" in
      python|ruby|lua|php|kotlin)
        # shellcheck source=nix/scripts/language-setup.sh
        source nix/scripts/language-setup.sh
        nix_setup_language "$lane" interop
        ;;
    esac
    if [[ "$lane" == kotlin ]]; then
      for adapter in kotlin-conformance kotlin-client kotlin-x402-client kotlin-x402-upto-client; do
        (cd "harness/$adapter" && gradle installDist --no-daemon)
      done

    fi
    python3 nix/scripts/interop.py "$lane"
    ;;
  browser)
    prepare_harness
    stage html-browser-deps
    stage typescript-unit
    bash nix/scripts/browser.sh "$lane"
    ;;
  demo) bash nix/scripts/demos.sh "$lane" ;;
  *) printf 'Unknown check kind: %s\n' "$kind" >&2; exit 2 ;;
esac
