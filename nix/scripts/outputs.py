#!/usr/bin/env python3
"""Evaluate explicit output contracts for build reuse and runtime transfer."""
import argparse
import json
from pathlib import Path
import subprocess

INTEROP_LINUX = ["html-assets", "typescript-sdk", "harness-deps", "rust-harness", "go-client", "go-server"]
RUNTIME = {
    "linux": INTEROP_LINUX + ["html-browser-deps", "typescript-unit"],
    "darwin": ["html-assets", "typescript-sdk", "harness-deps", "rust-harness", "swift-harness"],
}
SCOPES = {
    "shared-linux": RUNTIME["linux"] + ["rust-harness-deps"],
    "shared-darwin": RUNTIME["darwin"] + ["rust-harness-deps", "swift-compiler", "swift-package-manager"],
    "swift-tools": ["swift-compiler", "swift-package-manager"],
    "playground-rust": ["rust-playground-server", "rust-playground-deps"],
    "unit-typescript": ["html-assets", "typescript-unit"],
    "unit-audit": ["typescript-audit"],
    "unit-html": ["html-assets"],
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scope", choices=SCOPES)
    parser.add_argument("runner")
    parser.add_argument("--system", choices=["x86_64-linux", "aarch64-darwin"])
    args = parser.parse_args()
    system = args.system or ("aarch64-darwin" if args.scope in ["shared-darwin", "swift-tools"] else "x86_64-linux")
    names = "[ " + " ".join(json.dumps(name) for name in SCOPES[args.scope]) + " ]"
    expression = "packages: builtins.listToAttrs (builtins.map (name: { inherit name; value = { path = packages.${name}.outPath; drv = packages.${name}.drvPath; }; }) " + names + ")"
    data = json.loads(subprocess.check_output([
        "nix", "eval", "--json", "--no-update-lock-file", f".#packages.{system}",
        "--apply", expression,
    ], text=True))
    result = {"system": system, "runner": args.runner,
              "roots": {name: value["path"] for name, value in data.items()},
              "derivations": {name: value["drv"] for name, value in data.items()}}
    directory = Path(".nix-results")
    directory.mkdir(exist_ok=True)
    path = directory / f"expected-{args.scope}.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(path)

if __name__ == "__main__":
    main()
