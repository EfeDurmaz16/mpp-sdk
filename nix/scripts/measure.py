#!/usr/bin/env python3
"""Record preparation/build timings without storing environment secrets."""

import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time


def append(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def command(args):
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.run(args.argv, check=False)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    append(args.results, {
        "label": args.label, "seconds": time.monotonic() - started,
        "exit_code": process.returncode,
        "child_user_seconds": after.ru_utime - before.ru_utime,
        "child_system_seconds": after.ru_stime - before.ru_stime,
        # Darwin reports bytes; Linux reports KiB. Preserve units explicitly.
        "child_max_rss": after.ru_maxrss,
        "rss_units": "bytes" if sys.platform == "darwin" else "KiB",
    })
    return process.returncode if process.returncode >= 0 else 128 - process.returncode


def outputs(args):
    roots = json.loads(args.expected.read_text())["roots"]
    info = json.loads(subprocess.check_output([
        "nix", "path-info", "--json", "--recursive", *roots.values(),
    ], text=True))
    # Nix 2.35 returns a path-keyed object; retain only non-secret metadata.
    entries = info.items() if isinstance(info, dict) else ((p["path"], p) for p in info)
    paths = [{"path": path, "nar_bytes": entry.get("narSize"),
              "references": entry.get("references", [])} for path, entry in entries]
    result = {"roots": roots, "closure_path_count": len(paths),
              "closure_nar_bytes": sum(p["nar_bytes"] or 0 for p in paths), "paths": paths}
    if args.files:
        counts = {"files": 0, "directories": 0, "symlinks": 0, "logical_bytes": 0}
        for output in roots.values():
            for directory, subdirs, files in os.walk(output, followlinks=False):
                for name in [*subdirs, *files]:
                    path = Path(directory) / name
                    if path.is_symlink():
                        counts["symlinks"] += 1
                    elif path.is_dir():
                        counts["directories"] += 1
                    else:
                        counts["files"] += 1
                        counts["logical_bytes"] += path.stat().st_size
        result["selected_root_file_counts"] = counts
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps(result, indent=2) + "\n")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    cmd = sub.add_parser("command")
    cmd.add_argument("--results", type=Path, required=True)
    cmd.add_argument("--label", required=True)
    cmd.add_argument("argv", nargs=argparse.REMAINDER)
    paths = sub.add_parser("outputs")
    paths.add_argument("--expected", type=Path, required=True)
    paths.add_argument("--results", type=Path, required=True)
    paths.add_argument("--files", action="store_true")
    args = parser.parse_args()
    if args.mode == "command":
        if args.argv and args.argv[0] == "--":
            args.argv = args.argv[1:]
        if not args.argv:
            parser.error("a command is required")
        return command(args)
    return outputs(args)


if __name__ == "__main__":
    raise SystemExit(main())
