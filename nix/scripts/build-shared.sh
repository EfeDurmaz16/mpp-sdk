#!/usr/bin/env bash
set -euo pipefail
exec python3 - "${1:?linux or darwin is required}" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import time

platform = sys.argv[1]
if platform not in ("linux", "darwin"):
    raise SystemExit("Expected linux or darwin")
targets = ["html-assets", "typescript-sdk", "harness-deps", "rust-harness"]
if platform == "linux":
    targets += ["go-client", "go-server"]
results = Path(".nix-results")
results.mkdir(exist_ok=True)
command = ["nix", "build", "--no-update-lock-file", "--no-link", "--json"]
command += [f".#{target}" for target in targets]
measurements = []
previous = None
for label in ("initial-store", "warm-store"):
    started = time.monotonic()
    process = subprocess.run(command, capture_output=False, stdout=subprocess.PIPE, text=True)
    elapsed = time.monotonic() - started
    measurements.append({"label": label, "seconds": elapsed, "exit_code": process.returncode})
    (results / "shared-build-times.json").write_text(json.dumps(measurements, indent=2) + "\n")
    process.check_returncode()
    data = json.loads(process.stdout)
    paths = sorted({path for output in data for path in output["outputs"].values()})
    if previous is not None and paths != previous:
        raise SystemExit("Warm build changed the shared output paths")
    previous = paths
    (results / f"shared-{label}.json").write_text(json.dumps(data, indent=2) + "\n")
    print(f"{label}: {elapsed:.3f}s, {len(paths)} shared outputs", flush=True)
(results / "shared-roots.txt").write_text("\n".join(previous) + "\n")
PY
