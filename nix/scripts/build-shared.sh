#!/usr/bin/env bash
set -euo pipefail
exec python3 - "${1:?linux or darwin is required}" <<'PYTHON'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path("nix/scripts").resolve()))
from outputs import INTEROP_LINUX, RUNTIME

platform = sys.argv[1]
if platform not in RUNTIME:
    raise SystemExit("Expected linux or darwin")
scope = "shared-" + platform
runner = "ubuntu-24.04" if platform == "linux" else "macos-26"
subprocess.run(["python3", "nix/scripts/outputs.py", scope, runner], check=True)
expected = Path(f".nix-results/expected-{scope}.json")
contract = json.loads(expected.read_text())
targets = list(contract["roots"])
command = ["nix", "build", "--no-update-lock-file", "--no-link", "--json"]
command += [f".#{target}" for target in targets]
results = Path(".nix-results")
measurements = []
for label in ("initial-store", "warm-store"):
    started = time.monotonic()
    process = subprocess.run(command, stdout=subprocess.PIPE, text=True)
    elapsed = time.monotonic() - started
    measurements.append({"label": label, "seconds": elapsed, "exit_code": process.returncode})
    (results / "shared-build-times.json").write_text(json.dumps(measurements, indent=2) + "\n")
    process.check_returncode()
    # Select outputs explicitly: dev and out are built together, but dependency
    # artifacts do not belong in runtime archives sent to every consumer.
    paths = sorted(set(contract["roots"].values()))
    subprocess.run(["nix-store", "--check-validity", *paths], check=True)
    (results / f"shared-{label}.json").write_text(process.stdout)
    print(f"{label}: {elapsed:.3f}s, {len(paths)} selected outputs", flush=True)
runtime = sorted(contract["roots"][name] for name in RUNTIME[platform])
(results / "shared-roots.txt").write_text("\n".join(runtime) + "\n")
if platform == "linux":
    interop = sorted(contract["roots"][name] for name in INTEROP_LINUX)
    (results / "interop-roots.txt").write_text("\n".join(interop) + "\n")
    (results / "browser-roots.txt").write_text("\n".join(runtime) + "\n")
(results / "cache-roots.txt").write_text("\n".join(paths) + "\n")
profile = ["python3", "nix/scripts/measure.py", "outputs", "--expected", str(expected),
           "--results", str(results / "shared-closure.json")]
if os.environ.get("NIX_PROFILE_OUTPUTS") == "true":
    profile.append("--files")
subprocess.run(profile, check=True)
PYTHON
