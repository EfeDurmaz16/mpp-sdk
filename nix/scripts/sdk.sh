#!/usr/bin/env bash
# Run inside the matching Nix shell after the shared artifacts are staged.
set -euo pipefail

mode="${1:?Usage: bash nix/scripts/sdk.sh <typescript|rust|go|audit|html>}"
case "$mode" in typescript|rust|go|audit|html) ;; *) echo "Unknown SDK gate: $mode" >&2; exit 2 ;; esac
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
results="$root/.nix-results/$mode"
mkdir -p "$results"
redis_pid=""

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
collect_reports() {
  local status=$?
  trap - EXIT
  if [[ -n "$redis_pid" ]]; then
    kill "$redis_pid" 2>/dev/null || true
    wait "$redis_pid" 2>/dev/null || true
  fi
  local source_path
  if (( ${#reports[@]} )); then
    for source_path in "${reports[@]}"; do
      if [[ -e "$source_path" ]]; then cp -R "$source_path" "$results/" || status=1; fi
    done
  fi
  exit "$status"
}
reports=()
trap collect_reports EXIT
status=0
cd "$root"

case "$mode" in
  typescript)
    reports=("$root/typescript/coverage/coverage-summary.json" "$root/typescript/target/surfpool-reports")
    cd typescript
    # The shared SDK artifact already contains @solana/mpp's dist exports.
    pnpm lint || status=1
    pnpm format:check || status=1
    pnpm typecheck || status=1
    pnpm vitest run --coverage --config vitest.config.ci.ts || status=1
    pnpm test:integration || status=1
    ;;
  rust)
    reports=("$root/rust/coverage.json" "$root/rust/target/surfpool-reports")
    cp nix/locks/rust-Cargo.lock rust/Cargo.lock
    cd rust
    # Bind a fresh local port and stop only the process this invocation owns.
    redis_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
    )"
    redis-server --bind 127.0.0.1 --port "$redis_port" --save '' \
      --appendonly no --daemonize no >"$results/redis.log" 2>&1 &
    redis_pid=$!
    ready=false
    for _ in {1..50}; do
      kill -0 "$redis_pid" 2>/dev/null || { cat "$results/redis.log" >&2; exit 1; }
      if [[ "$(redis-cli -h 127.0.0.1 -p "$redis_port" ping 2>/dev/null)" == PONG ]]; then ready=true; break; fi
      sleep 0.1
    done
    if [[ "$ready" != true ]]; then echo 'Redis did not become ready' >&2; exit 1; fi
    export PAY_KIT_TEST_REDIS_URL="redis://127.0.0.1:$redis_port"
    cargo llvm-cov --locked -p solana-pay-kit -p paykit-integration-tests \
      --ignore-filename-regex 'crates/integration-tests/|crates/harness-bins/|src/mpp/program/|src/x402/|src/generated/' \
      --json --output-path coverage.json || status=1
    cargo test --locked -p solana-pay-kit --lib x402 || status=1
    cargo test --locked -p solana-pay-kit --features redis-store --lib \
      core::store::tests::redis_channel_store_roundtrip_and_atomic_watermark -- --exact || status=1
    python3 - <<'PY' || status=1
import json, sys
with open('coverage.json') as handle:
    pct = json.load(handle)['data'][0]['totals']['lines']['percent']
floor = 90.0
print(f'Rust line coverage: {pct:.2f}% (floor {floor})')
if pct < floor:
    sys.exit(f'FAIL: {pct:.2f}% < {floor}')
PY
    cargo fmt --check || status=1
    ;;
  go)
    reports=("$root/go/coverage.out")
    export GOTOOLCHAIN=local GOWORK=off
    cd go
    # Keep the native workflow's hand-written SDK coverage scope and floor.
    go test -mod=readonly \
      github.com/solana-foundation/pay-kit/go/paycore \
      github.com/solana-foundation/pay-kit/go/paycore/solanatx \
      github.com/solana-foundation/pay-kit/go/paycore/signer \
      github.com/solana-foundation/pay-kit/go/paycore/paymentchannels \
      github.com/solana-foundation/pay-kit/go/paykit \
      github.com/solana-foundation/pay-kit/go/paykit/adapters/x402 \
      github.com/solana-foundation/pay-kit/go/paykit/adapters/mpp \
      github.com/solana-foundation/pay-kit/go/protocols/mpp \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/core \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/wire \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/intents \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/server \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/client \
      github.com/solana-foundation/pay-kit/go/protocols/mpp/errorcodes \
      github.com/solana-foundation/pay-kit/go/protocols/x402 \
      github.com/solana-foundation/pay-kit/go/protocols/x402/client \
      -coverprofile=coverage.out -covermode=atomic || status=1
    ./scripts/check_coverage.sh coverage.out 91 || status=1
    # Explicit addition: SDK tests do not traverse the two adapter modules.
    for module in go harness/go-client harness/go-server; do
      (cd "$root/$module" && go test -mod=readonly -count=1 ./...) || status=1
    done
    unformatted="$(find . -name '*.go' -not -path './vendor/*' -print0 | xargs -0 gofmt -l)"
    if [[ -n "$unformatted" ]]; then printf '::error::gofmt drift:\n%s\n' "$unformatted"; status=1; fi
    golangci-lint run --timeout=5m || status=1
    ;;
  audit)
    cd typescript
    if output="$(pnpm audit --production 2>&1)"; then
      printf '%s\n' "$output"
    else
      printf '%s\n' "$output"
      if [[ "$output" == *'This endpoint is being retired'* ]]; then
        echo '::warning::npm quick-audit endpoint retired (410); pnpm audit unavailable until pnpm supports the bulk advisory endpoint'
      else status=1; fi
    fi
    ;;
  html)
    # The html-assets derivation runs the generator; staging copies its outputs.
    generated=(rust/crates/kit/src/mpp/server/html/ go/protocols/mpp/server/html/
      lua/pay_kit/protocols/mpp/server/html_assets/ python/src/pay_kit/protocols/mpp/server/html/)
    if ! git diff --quiet -- "${generated[@]}"; then
      echo "::error::Generated files are out of date. Run 'just html-build' and commit the results."
      git diff --stat -- "${generated[@]}"
      status=1
    fi
    ;;
esac
exit "$status"
