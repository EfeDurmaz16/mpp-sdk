#!/usr/bin/env bash
# Key and retain only the expensive outputs reused by the two producer jobs.
set -euo pipefail
exec python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

if len(sys.argv) not in (3, 4):
    raise SystemExit("Usage: cache-roots.sh <key|record|root> <shared-linux|interop-swift> [runner-label]")
operation, scope = sys.argv[1:3]
if operation not in ("key", "record", "root") or scope not in ("shared-linux", "interop-swift"):
    raise SystemExit("Unsupported cache operation or scope")
system = {("Linux", "x86_64"): "x86_64-linux", ("Darwin", "arm64"): "aarch64-darwin"}.get(
    (platform.system(), platform.machine())
)
expected = "x86_64-linux" if scope == "shared-linux" else "aarch64-darwin"
if system != expected:
    raise SystemExit(f"{scope} requires {expected}; got {system}")

results = Path(".nix-results")
results.mkdir(exist_ok=True)


def output(command):
    return subprocess.check_output(command, text=True).strip()


if operation == "key":
    if len(sys.argv) != 4 or not re.fullmatch(r"[A-Za-z0-9_.-]+", sys.argv[3]):
        raise SystemExit("A runner image label is required for the cache key")
    runner = sys.argv[3]
    targets = ["html-assets", "typescript-sdk", "harness-deps", "rust-harness"]
    if scope == "shared-linux":
        targets.extend(["go-client", "go-server"])
    names = " ".join(json.dumps(target) for target in targets)
    expression = f"packages: builtins.map (name: packages.${{name}}.drvPath) [ {names} ]"
    paths = json.loads(output([
        "nix", "eval", "--json", "--no-update-lock-file", f".#packages.{system}",
        "--apply", expression,
    ]))
    if len(paths) != len(targets):
        raise SystemExit("Nix returned an incomplete derivation set")
    derivations = dict(zip(targets, paths))
    if scope == "interop-swift":
        derivations["ci-interop-swift"] = output([
            "nix", "eval", "--raw", "--no-update-lock-file",
            f".#devShells.{system}.ci-interop-swift.drvPath",
        ])
    version = re.search(r"\b(\d+\.\d+\.\d+)\b", output(["nix", "--version"]))
    if version is None:
        raise SystemExit("Could not identify the installed Nix version")
    lock_hash = hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest()
    digest = hashlib.sha256(json.dumps(derivations, sort_keys=True).encode()).hexdigest()
    prefix = f"nix-experiment-v1-{scope}-{runner}-{system}-nix{version[1]}-{lock_hash[:16]}-"
    key = prefix + digest
    metadata = {
        "schema": 1, "scope": scope, "runner": runner, "system": system,
        "nix_version": version[1], "flake_lock_sha256": lock_hash,
        "derivations": derivations, "primary_key": key, "restore_prefix": prefix,
    }
    (results / f"cache-{scope}.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
        handle.write(f"primary-key={key}\nrestore-prefix={prefix}\n")
    print(f"Cache scope {scope}: {len(derivations)} derivations, key {key}")
elif operation == "record":
    metadata_file = results / f"cache-{scope}.json"
    metadata = json.loads(metadata_file.read_text())
    restored_key = os.environ.get("CACHE_RESTORED_KEY", "")
    metadata.update({
        "hit_primary_key": os.environ.get("CACHE_HIT_PRIMARY_KEY", "") == "true",
        "restored_key": restored_key,
        "restored": bool(restored_key),
    })
    metadata_file.write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Cache scope {scope}: restored {restored_key or 'none (miss)'}")
else:
    roots_file = results / "shared-roots.txt"
    roots = roots_file.read_text().splitlines()
    expected_count = 6 if scope == "shared-linux" else 4
    if len(roots) != expected_count or len(set(roots)) != expected_count:
        raise SystemExit(f"Expected {expected_count} distinct successful shared build outputs")
    directory = Path(".nix-work/cache-roots") / scope
    directory.mkdir(parents=True, exist_ok=True)
    for index, root in enumerate(roots):
        if not re.fullmatch(r"/nix/store/[0-9a-z]{32}-[^/\s]+", root):
            raise SystemExit(f"Invalid store output: {root!r}")
        # Do not fetch or rebuild outputs if the preceding shared build failed.
        subprocess.run(["nix-store", "--check-validity", root], check=True)
        subprocess.run([
            "nix-store", "--realise", root, "--add-root",
            str((directory / f"shared-{index}").absolute()),
        ], check=True)
    if scope == "interop-swift":
        # This records the already used shell and retains its Swift runtime/tools.
        subprocess.run([
            "nix", "develop", "--no-update-lock-file", ".#ci-interop-swift",
            "--profile", str((directory / "environment").absolute()),
            "--command", "true",
        ], check=True)
    print(f"Protected {len(roots)} shared outputs for {scope}")
PY
