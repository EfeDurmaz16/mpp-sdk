#!/usr/bin/env python3
"""Describe dependency-only runtime caches for the experimental Nix lanes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone


CONFIG = {
    "python": {
        "patterns": ["python/pyproject.toml", "python/uv.lock"],
        "paths": [".nix-work/cache/pip", ".nix-work/cache/uv"],
        "env": {"PIP_CACHE_DIR": ".nix-work/cache/pip", "UV_CACHE_DIR": ".nix-work/cache/uv"},
    },
    "ruby": {
        "patterns": ["ruby/Gemfile*", "ruby/*.gemspec"],
        "paths": [".nix-work/bundle"],
        "env": {"BUNDLE_PATH": ".nix-work/bundle"},
    },
    "lua": {
        "patterns": ["lua/*.rockspec", "lua/.luacov", "lua/.luacheckrc"],
        "paths": ["lua/lua_modules"],
        "env": {},
    },
    "php": {
        "patterns": ["php/composer.json", "php/composer.lock"],
        "paths": [".nix-work/cache/composer/files"],
        "env": {"COMPOSER_CACHE_DIR": ".nix-work/cache/composer"},
    },
    "kotlin": {
        "patterns": ["kotlin/*.gradle.kts", "kotlin/gradle.properties", "kotlin/gradle/**/*.toml", "kotlin/gradle/**/*.properties", "harness/kotlin*/*.gradle.kts", "harness/kotlin*/gradle.properties"],
        "paths": [".nix-work/gradle/caches/modules-2", "!.nix-work/gradle/caches/modules-2/**/*.lock", "!.nix-work/gradle/caches/modules-2/gc.properties"],
        "env": {"GRADLE_USER_HOME": ".nix-work/gradle"},
    },
    "go": {
        "patterns": ["go/go.mod", "go/go.sum", "harness/go-*/go.mod", "harness/go-*/go.sum"],
        "paths": [".nix-work/go/pkg/mod"],
        "env": {"GOMODCACHE": ".nix-work/go/pkg/mod"},
    },
}


def contract(root, language, lane, purpose, shell_derivation, runner_os, runner_arch):
    config = CONFIG[language]
    lanes = json.loads((root / "nix/ci-lanes.json").read_text())
    expected = [item for item in lanes if item["id"] == lane]
    if len(expected) != 1 or expected[0]["language"] != language or expected[0]["kind"] != purpose:
        raise ValueError("Cache lane, language and purpose must match nix/ci-lanes.json")
    if not shell_derivation.startswith("/nix/store/") or not shell_derivation.endswith(".drv"):
        raise ValueError("Expected an exact Nix shell derivation")
    files = {root / "nix/scripts/language-cache.py", root / "nix/scripts/language-setup.sh"}
    for pattern in config["patterns"]:
        files.update(path for path in root.glob(pattern) if path.is_file())
    digest = hashlib.sha256()
    inputs = []
    for path in sorted(files):
        name = str(path.relative_to(root))
        content = path.read_bytes()
        digest.update(name.encode() + b"\0" + content + b"\0")
        inputs.append(name)
    # Native Lua CI also reuses installed rocks. With no rock lockfile, bound
    # that reuse to one UTC week instead of freezing mutable upstream versions.
    freshness = datetime.now(timezone.utc).strftime("%G-W%V") if language == "lua" else "locked"
    key = f"nix-language-v1-{runner_os}-{runner_arch}-{lane}-{Path(shell_derivation).name}-{digest.hexdigest()}-{freshness}"
    return {
        "language": language, "lane": lane, "purpose": purpose,
        "shell_derivation": shell_derivation, "key": key,
        "freshness": freshness, "inputs": inputs, "paths": config["paths"],
        "environment": {key: str(root / value) for key, value in config["env"].items()},
        "cache_policy": "dependencies only; tests, coverage, project build outputs and virtualenvs excluded",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("language", choices=CONFIG)
    parser.add_argument("lane")
    parser.add_argument("purpose", choices=["unit", "interop", "browser"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    runner_os = os.environ["RUNNER_OS"]
    runner_arch = os.environ["RUNNER_ARCH"]
    systems = {("Linux", "X64"): "x86_64-linux", ("macOS", "ARM64"): "aarch64-darwin"}
    system = systems[(runner_os, runner_arch)]
    shell_derivation = subprocess.check_output([
        "nix", "eval", "--no-update-lock-file", "--raw",
        f".#devShells.{system}.ci-{args.lane}.drvPath",
    ], cwd=root, text=True).strip()
    result = contract(root, args.language, args.lane, args.purpose, shell_derivation, runner_os, runner_arch)
    output = root / f".nix-results/cache-{args.lane}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
        handle.write(f"key={result['key']}\npaths<<LANGUAGE_CACHE_PATHS\n")
        handle.write("\n".join(result["paths"]) + "\nLANGUAGE_CACHE_PATHS\n")
    with open(os.environ["GITHUB_ENV"], "a") as handle:
        for name, value in result["environment"].items():
            if "\n" in value or "\r" in value:
                raise ValueError("Cache environment paths must fit on one line")
            handle.write(f"{name}={value}\n")
        if args.language == "kotlin":
            # Only dependency downloads are restored, not task outputs.
            handle.write("GRADLE_OPTS=-Dorg.gradle.daemon=false -Dorg.gradle.caching=false\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
