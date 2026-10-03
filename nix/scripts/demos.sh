#!/usr/bin/env bash
# Native platform SDKs remain explicit runtime exceptions to the Nix experiment.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lane="${1:?usage: demos.sh android-demo|ios-demo}"
case "$lane" in
  android-demo|ios-demo) ;;
  *) printf 'Unknown demo lane: %s\n' "$lane" >&2; exit 2 ;;
esac
results="$root/.nix-results/$lane"
mkdir -p "$results"
host_xcodebuild() {
  # Xcode treats exported compiler variables as build settings. Nix exports
  # LD=ld, but Xcode's link commands need its clang driver to consume -Xlinker.
  # Run the declared host-SDK exception with only its user and system context.
  python3 - "$@" <<'PY'
import os
import subprocess
import sys

environment = {name: os.environ[name] for name in (
    "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CI"
) if name in os.environ}
environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
environment["DEVELOPER_DIR"] = subprocess.check_output(
    ["/usr/bin/xcode-select", "--print-path"], env=environment, text=True
).strip()
os.execve("/usr/bin/xcodebuild", ["xcodebuild", *sys.argv[1:]], environment)
PY
}
case "$lane" in
  android-demo)
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -z "$sdk" || ! -d "$sdk/platforms/android-34" || ! -d "$sdk/build-tools/34.0.0" ]]; then
      printf 'Android demo requires host SDK platform 34 and build-tools 34.0.0.\n' >&2
      exit 1
    fi
    export ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk"
    {
      printf 'lane=%s\nmode=networked-runtime\n' "$lane"
      printf 'exception=host Android SDK, platform 34, build-tools 34.0.0\n'
      printf 'gradle=repository wrapper, downloads permitted\n'
      java -version 2>&1
    } >"$results/runtime.txt"
    cd "$root/kotlin/examples/AndroidDemo"
    ./gradlew :app:assembleDebug --no-daemon --stacktrace
    test -f app/build/outputs/apk/debug/app-debug.apk
    ;;
  ios-demo)
    [[ "$(uname -s)" == Darwin ]] || { printf 'iOS demo requires a macOS Xcode runner.\n' >&2; exit 1; }
    {
      printf 'lane=%s\nmode=networked-runtime\nexception=host Xcode and iOS Simulator SDK\n' "$lane"
      host_xcodebuild -version
      host_xcodebuild -showsdks
    } >"$results/runtime.txt"
    cd "$root/swift/Examples/PayKitDemo"
    host_xcodebuild -scheme PayKitDemo -project PayKitDemo.xcodeproj \
      -destination 'generic/platform=iOS Simulator' -configuration Debug CODE_SIGNING_ALLOWED=NO build
    ;;
esac
