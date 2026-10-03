#!/usr/bin/env bash
# Usage: store-artifact.sh export DIRECTORY /nix/store/OUTPUT [...]
#        EXPECTED_MANIFEST_SHA256=... store-artifact.sh import DIRECTORY
# Transfer only between jobs of this same GitHub-hosted workflow run. Download
# the producer's artifact ID, then pass its manifest_sha256 JOB OUTPUT separately.
# The manifest detects corruption; trust comes from the authenticated workflow
# producer and that separate output, not from a hash bundled with arbitrary code.
# Import grants root only to this verified NAR stream. No daemon trust/signature
# settings change. The runner remains untrusted to the Nix daemon afterward.
# https://nix.dev/manual/nix/2.35/command-ref/nix-store/export.html
# https://nix.dev/manual/nix/2.35/command-ref/nix-store/import.html
set -euo pipefail
exec python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

FILES = ("closure.nar", "roots.txt", "paths.txt", "metadata.json")
CONTEXT = ("GITHUB_REPOSITORY", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")
STORE_PATH = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args):
    return command(*args, stdout=subprocess.PIPE, text=True).stdout.strip()


def digest(path):
    with path.open("rb") as stream:
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
        return result.hexdigest()


def path_list(lines):
    require(bool(lines) and len(lines) == len(set(lines)), "Empty or duplicated store path list")
    require(all(STORE_PATH.fullmatch(p) and not p.endswith(".drv") for p in lines),
            "Only complete output store paths are allowed; derivations are not runtime outputs")
    return sorted(lines)


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    require(len(sys.argv) >= 3, "Usage: store-artifact.sh export|import DIRECTORY [OUTPUT ...]")
    mode, directory = sys.argv[1], Path(sys.argv[2]).absolute()
    require(mode in ("export", "import"), "Unknown store artifact operation")
    require(os.environ.get("GITHUB_ACTIONS") == "true", "Transfer is restricted to GitHub Actions")
    require(all(os.environ.get(key) for key in CONTEXT), "Missing same-run workflow context")
    context = {key: os.environ[key] for key in CONTEXT}
    system = output("nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem")
    require(re.fullmatch(r"[a-z0-9_]+-(linux|darwin)", system) is not None, "Unsupported Nix system")
    if mode == "export":
        roots = path_list(sys.argv[3:])
        require(not directory.is_symlink(), "Artifact directory cannot be a symlink")
        directory.mkdir(parents=True, exist_ok=True)
        require(not any(directory.iterdir()), "Export directory must be empty")
        # Query output references, not .drv build dependencies or --include-outputs.
        paths = path_list(output("nix-store", "--query", "--requisites", *roots).splitlines())
        require(set(roots) <= set(paths), "Runtime closure omitted a requested root")
        (directory / "roots.txt").write_text("\n".join(roots) + "\n")
        (directory / "paths.txt").write_text("\n".join(paths) + "\n")
        write_json(directory / "metadata.json", {"format": 1, "system": system, "workflow": context})
        with (directory / "closure.nar").open("wb") as stream:
            command("nix-store", "--export", *paths, stdout=stream)
        write_json(directory / "manifest.json", {name: digest(directory / name) for name in FILES})
        expected = digest(directory / "manifest.json")
        print(f"manifest_sha256={expected}")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write(f"manifest_sha256={expected}\n")
        print(f"Exported {len(roots)} roots and {len(paths)} runtime paths for {system}")
        return

    require(len(sys.argv) == 3, "Import accepts only the downloaded artifact directory")
    require(os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "Unsigned closure import is restricted to disposable GitHub-hosted runners")
    expected = os.environ.get("EXPECTED_MANIFEST_SHA256", "")
    require(re.fullmatch(r"[0-9a-f]{64}", expected) is not None,
            "Set EXPECTED_MANIFEST_SHA256 from the producer's job output")
    require(not directory.is_symlink(), "Artifact directory cannot be a symlink")
    require({p.name for p in directory.iterdir()} == set(FILES) | {"manifest.json"},
            "Unexpected or missing artifact files")
    for name in (*FILES, "manifest.json"):
        require(stat.S_ISREG((directory / name).lstat().st_mode), "Artifact files must be regular files")
    require(digest(directory / "manifest.json") == expected, "Manifest SHA256 mismatch")
    manifest = json.loads((directory / "manifest.json").read_text())
    require(isinstance(manifest, dict) and set(manifest) == set(FILES), "Invalid manifest file list")
    for name in FILES:
        require(digest(directory / name) == manifest[name], f"SHA256 mismatch: {name}")
    metadata = json.loads((directory / "metadata.json").read_text())
    require(metadata == {"format": 1, "system": system, "workflow": context},
            "Artifact system or workflow run/repository/attempt/commit does not match")
    roots = path_list((directory / "roots.txt").read_text().splitlines())
    paths = path_list((directory / "paths.txt").read_text().splitlines())
    require(set(roots) <= set(paths), "Runtime closure omitted a root")
    nix_store = shutil.which("nix-store")
    require(nix_store is not None, "nix-store is unavailable")
    require(str(Path(nix_store).resolve(strict=True)).startswith("/nix/store/"),
            "Privileged importer must be the installed Nix store binary")
    # Keep the nix-store basename: recent Nix releases use a multicall symlink.
    nix_store = str(Path(nix_store).parent.resolve(strict=True) / "nix-store")
    # Nix 2.35 opImport requests NoCheckSigs. The daemon only honors that for
    # trusted clients (root by default), so privilege only this verified stream.
    # Do not use sudo -E or execute a downloaded script as root.
    with (directory / "closure.nar").open("rb") as stream:
        imported = command("sudo", "-n", "--", nix_store, "--import", stdin=stream,
                           stdout=subprocess.PIPE, text=True).stdout.splitlines()
    require(path_list(imported) == paths, "Imported store paths differ from the verified manifest")
    actual = path_list(output("nix-store", "--query", "--requisites", *roots).splitlines())
    require(actual == paths, "Imported runtime closure differs from the verified manifest")
    print(f"Imported {len(roots)} roots and {len(paths)} runtime paths for {system}")
    print("\n".join(roots))


try:
    main()
except (ValueError, OSError, subprocess.CalledProcessError) as error:
    print(f"store-artifact: {error}", file=sys.stderr)
    sys.exit(1)
PY
