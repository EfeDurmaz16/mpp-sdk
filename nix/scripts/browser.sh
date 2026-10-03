#!/usr/bin/env bash
# Runtime checks preserve the native Playwright selections. Network access and
# downloaded browsers are intentional; these are not sandboxed Nix checks.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lane="${1:?usage: browser.sh playground-smoke|playground-e2e|playground-typescript|playground-rust|playground-go}"
case "$lane" in
  playground-smoke|playground-e2e|playground-typescript|playground-rust|playground-go) ;;
  *) printf 'Unknown browser lane: %s\n' "$lane" >&2; exit 2 ;;
esac
results="$root/.nix-results/$lane"
mkdir -p "$results"
export PLAYWRIGHT_BROWSERS_PATH="$root/.nix-runtime/playwright/$lane"
export pnpm_config_verify_deps_before_run=false
# run.sh stages these Nix outputs. Reinstallation can replace patched addons,
# so a missing output is a preparation error, never a reason to rebuild here.
for prepared in \
  html/dist/template.html \
  html/node_modules/.bin/playwright \
  harness/node_modules/@solana/surfpool/package.json \
  typescript/node_modules/.bin/tsc \
  typescript/packages/mpp/dist/index.js \
  typescript/packages/pay-kit/dist/index.js; do
  if [[ ! -f "$root/$prepared" ]]; then
    printf 'Missing prepared Nix output: %s; run the browser lane through nix/scripts/run.sh.\n' "$prepared" >&2
    exit 1
  fi
done
groups=()
last_pid=''
cleanup() {
  local status=$? pid
  trap - EXIT INT TERM
  if ((${#groups[@]})); then
    for pid in "${groups[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${groups[@]}"; do
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_in() { local directory=$1; shift; (cd "$root/$directory" && "$@"); }
start_group() {
  local name=$1 directory=$2; shift 2
  (
    cd "$root/$directory"
    exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  ) >"$results/$name.log" 2>&1 &
  last_pid=$!
  groups+=("$last_pid")
}
check_port() {
  node - "$1" <<'NODE'
const net = require('node:net');
const server = net.createServer();
server.once('error', error => { console.error(error.message); process.exit(1); });
server.listen({ host: '::', port: Number(process.argv[2]) }, () => server.close());
NODE
}
wait_ready() {
  local name=$1 pid=$2 url=$3 attempts=$4 mode=${5:-http} attempt
  for ((attempt=0; attempt<attempts; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s exited before becoming ready; see %s/%s.log\n' "$name" "$results" "$name" >&2
      return 1
    fi
    if [[ "$mode" == rpc ]]; then
      if curl --max-time 2 -sf -X POST "$url" -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getHealth","params":[]}' | grep -q '"result":"ok"'; then return 0; fi
      sleep 0.2
    else
      if curl --max-time 2 -sf "$url" >/dev/null; then return 0; fi
      sleep 1
    fi
  done
  printf '%s did not become ready at %s; see %s/%s.log\n' "$name" "$url" "$results" "$name" >&2
  return 1
}
playwright() {
  local directory=$1; shift
  # Run the test and its webServer children in an owned group, including when
  # cancelled. Other jobs' servers are never killed by name or port.
  start_group playwright "$directory" "$@"
  local status=0
  wait "$last_pid" || status=$?
  cat "$results/playwright.log"
  return "$status"
}
patch_browsers() {
  [[ "$(uname -s)" == Linux ]] || return 0
  : "${NIX_BROWSER_INTERPRETER:?Nix browser interpreter is required}"
  : "${NIX_BROWSER_LIBRARY_PATH:?Nix browser libraries are required}"
  python3 - "$PLAYWRIGHT_BROWSERS_PATH" "$root" <<'PY'
import os
from pathlib import Path
import struct
import subprocess
import sys

cache, repository = (Path(value).resolve() for value in sys.argv[1:])
if not cache.is_relative_to(repository) or cache == repository:
    raise SystemExit("Browser patching requires a private cache inside the checkout")
if not cache.is_dir():
    raise SystemExit(f"Browser download directory is missing: {cache}")
interpreter = os.environ["NIX_BROWSER_INTERPRETER"]
libraries = os.environ["NIX_BROWSER_LIBRARY_PATH"].split(":")
executables = []
patched = 0
for directory, subdirs, files in os.walk(cache, followlinks=False):
    subdirs[:] = [name for name in subdirs if not (Path(directory) / name).is_symlink()]
    for name in files:
        path = Path(directory) / name
        if path.is_symlink():
            continue
        with path.open("rb") as artifact:
            header = artifact.read(64)
            if header[:4] != b"\x7fELF":
                continue
            endian = {1: "<", 2: ">"}.get(header[5])
            if endian is None or header[4] not in (1, 2):
                raise SystemExit(f"Unsupported ELF header: {path}")
            if struct.unpack_from(endian + "H", header, 16)[0] not in (2, 3):
                continue
            if header[4] == 2:
                offset = struct.unpack_from(endian + "Q", header, 32)[0]
                entry_size, count = struct.unpack_from(endian + "HH", header, 54)
            else:
                offset = struct.unpack_from(endian + "I", header, 28)[0]
                entry_size, count = struct.unpack_from(endian + "HH", header, 42)
            program_types = set()
            for index in range(count):
                artifact.seek(offset + index * entry_size)
                program_types.add(struct.unpack(endian + "I", artifact.read(4))[0])
        if 2 not in program_types:  # Static executables have no dynamic dependencies.
            continue
        old_rpath = subprocess.check_output(["patchelf", "--print-rpath", path], text=True).strip()
        rpath = ":".join(dict.fromkeys(["$ORIGIN", *libraries, *filter(None, old_rpath.split(":"))]))
        if old_rpath != rpath:
            subprocess.run(["patchelf", "--set-rpath", rpath, path], check=True)
        if 3 in program_types:  # Shared libraries have no PT_INTERP segment.
            old_interpreter = subprocess.check_output(["patchelf", "--print-interpreter", path], text=True).strip()
            if old_interpreter != interpreter:
                subprocess.run(["patchelf", "--set-interpreter", interpreter, path], check=True)
            executables.append(path)
        patched += 1
if not executables:
    raise SystemExit("No dynamic browser executables were found in the private cache")
for path in executables:
    check = subprocess.run([interpreter, "--list", path], capture_output=True, text=True)
    if check.returncode or "not found" in check.stdout:
        raise SystemExit(f"Browser dependency check failed for {path}:\n{check.stdout}{check.stderr}")
    for line in check.stdout.splitlines():
        resolved = line.strip().split(" => ")[-1].split(" (")[0]
        if resolved.startswith("/") and not (
            resolved.startswith("/nix/store/") or Path(resolved).is_relative_to(cache)
        ):
            raise SystemExit(f"Browser dependency escaped the Nix runtime: {resolved}")
print(f"Nix browser runtime: prepared {patched} ELF files; checked {len(executables)} executables")
PY
}

{
  printf 'lane=%s\nmode=networked-runtime\n' "$lane"
  printf 'browser=Playwright downloaded Chromium in a private cache; Linux loader and libraries from Nix\n'
  node --version
  pnpm --version
} >"$results/runtime.txt"

if [[ "$lane" == playground-smoke ]]; then
  check_port 5173
  run_in playground pnpm install --frozen-lockfile
  run_in playground pnpm exec playwright install chromium
  patch_browsers
  # The app predev hook only reinstalls/rebuilds the already staged SDK.
  playwright playground env pnpm_config_enable_pre_post_scripts=false \
    pnpm exec playwright test --config playwright.smoke.config.ts
  exit
fi

check_port 8899
check_port 8900
start_group surfnet . node harness/start-surfnet-proxy.mjs
wait_ready surfnet "$last_pid" http://localhost:8899 50 rpc

case "$lane" in
  playground-e2e|playground-typescript)
    if [[ "$lane" == playground-e2e ]]; then
      check_port 3000
      check_port 5173
      run_in playground pnpm install --frozen-lockfile
      # Preserve the other predev work explicitly; only prepare:sdk is supplied
      # by Nix. The API has its own workspace and lockfile.
      run_in typescript/examples/playground-api pnpm install --frozen-lockfile
      run_in playground node scripts/gen-snippets.mjs
      run_in playground pnpm exec playwright install chromium
      patch_browsers
      printf 'rpc=https://402.surfnet.dev:8899 (hosted state, not pinned)\n' >>"$results/runtime.txt"
      playwright playground env pnpm_config_enable_pre_post_scripts=false PLAYGROUND_DISABLE_SIDECAR=1 \
        RPC_URL=https://402.surfnet.dev:8899 VITE_RPC_URL=https://402.surfnet.dev:8899 pnpm test:e2e
      exit
    fi
    check_port 3000
    run_in typescript/examples/playground-api pnpm install --frozen-lockfile
    start_group server typescript/examples/playground-api env NETWORK=localnet PLAYGROUND_DISABLE_SIDECAR=1 npx tsx index.ts
    wait_ready server "$last_pid" http://localhost:3000/api/v1/health 15
    ;;
  playground-rust)
    check_port 3001
    server_output="$(nix build --no-update-lock-file --no-link --print-out-paths .#rust-playground-server)"
    printf 'server_output=%s\n' "$server_output" >>"$results/runtime.txt"
    start_group server rust "$server_output/bin/payment_link_server"
    wait_ready server "$last_pid" http://localhost:3001/health 15
    ;;
  playground-go)
    check_port 3002
    # Use the Nix runner's Go cache consistently for build and run.
    run_in go go build ./examples/playground-api
    start_group server go env PORT=3002 NETWORK=localnet RPC_URL=http://localhost:8899 \
      MPP_SECRET_KEY=playground-ci-secret-padding-0123456789 go run ./examples/playground-api
    wait_ready server "$last_pid" http://localhost:3002/api/v1/health 30
    ;;
esac
run_in html npx playwright install chromium
patch_browsers
case "$lane" in
  playground-typescript) playwright html npm run test:e2e:demo ;;
  playground-rust) playwright html npm run test:e2e:rust ;;
  playground-go) playwright html env FORTUNE_PATH=/api/v1/fortune npm run test:e2e:go ;;
esac
