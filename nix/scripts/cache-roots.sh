#!/usr/bin/env bash
# Key and retain only the current evaluated outputs for each producer scope.
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

sys.path.insert(0, str(Path("nix/scripts").resolve()))
from outputs import SCOPES

if len(sys.argv) not in (3, 4):
    raise SystemExit("Usage: cache-roots.sh <key|record|root> <scope> [runner-label]")
operation, scope = sys.argv[1:3]
if operation not in ("key", "record", "root") or scope not in SCOPES:
    raise SystemExit("Unsupported cache operation or scope")
system = {("Linux", "x86_64"): "x86_64-linux", ("Darwin", "arm64"): "aarch64-darwin"}.get(
    (platform.system(), platform.machine())
)
results = Path(".nix-results")
results.mkdir(exist_ok=True)
expected_file = Path(os.environ.get("CACHE_EXPECTED_FILE") or results / f"expected-{scope}.json")
if results.resolve() not in expected_file.resolve().parents:
    raise SystemExit("Expected output contract must be inside .nix-results")
expected = json.loads(expected_file.read_text())
if expected.get("system") != system or system is None:
    raise SystemExit(f"Expected output system {expected.get('system')!r} does not match {system!r}")
runner = expected.get("runner")
if not isinstance(runner, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", runner):
    raise SystemExit("Expected output contract requires an explicit runner image label")
if len(sys.argv) == 4 and sys.argv[3] and sys.argv[3] != runner:
    raise SystemExit("Runner image differs from the expected output contract")
store_path = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+")
roots = expected.get("roots")
derivations = expected.get("derivations")
if not isinstance(roots, dict) or not isinstance(derivations, dict):
    raise SystemExit("Expected output contract requires roots and derivations maps")
if set(roots) != set(SCOPES[scope]) or set(derivations) != set(roots):
    raise SystemExit(f"Expected output names must exactly match the current {scope} scope")
if any(not isinstance(path, str) or not store_path.fullmatch(path) or path.endswith(".drv")
       for path in roots.values()):
    raise SystemExit("Expected complete Nix output paths")
if any(not isinstance(path, str) or not store_path.fullmatch(path) or not path.endswith(".drv")
       for path in derivations.values()):
    raise SystemExit("Expected complete Nix derivation paths")
contract = {"system": system, "runner": runner, "roots": roots, "derivations": derivations}
metadata_file = results / f"cache-{scope}.json"


def output(command):
    return subprocess.check_output(command, text=True).strip()


if operation == "key":
    version = re.search(r"\b(\d+\.\d+\.\d+)\b", output(["nix", "--version"]))
    if version is None:
        raise SystemExit("Could not identify the installed Nix version")
    lock_hash = hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest()
    digest = hashlib.sha256(json.dumps(contract, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    # v3 has no legacy or prefix fallback. Both cache implementations consume
    # the same exact roots, unlike the former hard-coded six/four output lists.
    key = f"nix-experiment-v3-{scope}-{runner}-{system}-nix{version[1]}-{lock_hash[:16]}-{digest}"
    metadata = {
        "schema": 3, "scope": scope, **contract,
        "nix_version": version[1], "flake_lock_sha256": lock_hash,
        "expected_file": str(expected_file), "primary_key": key,
        "restore_policy": "exact current outputs only; no legacy or prefix fallback",
    }
    metadata_file.write_text(json.dumps(metadata, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
        handle.write(f"primary-key={key}\n")
    print(f"Cache scope {scope}: {len(roots)} evaluated outputs, key {key}")
else:
    metadata = json.loads(metadata_file.read_text())
    if metadata.get("schema") != 3 or metadata.get("scope") != scope:
        raise SystemExit("Current v3 restore metadata is required")
    if any(metadata.get(name) != value for name, value in contract.items()):
        raise SystemExit("Expected output contract changed after cache key evaluation")
    if metadata["flake_lock_sha256"] != hashlib.sha256(Path("flake.lock").read_bytes()).hexdigest():
        raise SystemExit("The flake lock changed after cache key evaluation")
    if operation == "record":
        restored_key = os.environ.get("CACHE_RESTORED_KEY", "")
        if restored_key and restored_key != metadata["primary_key"]:
            raise SystemExit("Only the exact current v3 cache key may be restored")
        metadata.update({
            "hit_primary_key": os.environ.get("CACHE_HIT_PRIMARY_KEY", "") == "true",
            "restored_key": restored_key, "restored": bool(restored_key),
        })
        metadata_file.write_text(json.dumps(metadata, indent=2) + "\n")
        print(f"Cache scope {scope}: restored {restored_key or 'none (miss)'}")
    else:
        if os.environ.get("CACHE_PRIMARY_KEY") != metadata["primary_key"]:
            raise SystemExit("A save must use the original exact restore key")
        # Check every root before registering any of them. Do not fetch or
        # rebuild missing outputs after a preceding producer build failed.
        unique_roots = sorted(set(roots.values()))
        subprocess.run(["nix-store", "--check-validity", *unique_roots], check=True)
        directory = Path(".nix-work/cache-roots") / scope
        directory.mkdir(parents=True, exist_ok=True)
        desired_names = {f"output-{index}" for index in range(len(unique_roots))}
        for previous in directory.iterdir():
            if previous.is_symlink() and previous.name not in desired_names:
                previous.unlink()
        for index, root in enumerate(unique_roots):
            subprocess.run([
                "nix-store", "--realise", root, "--add-root",
                str((directory / f"output-{index}").absolute()),
            ], check=True)
        print(f"Protected {len(unique_roots)} successful evaluated outputs for {scope}")
PY
