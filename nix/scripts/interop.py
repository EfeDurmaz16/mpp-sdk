#!/usr/bin/env python3
"""Run the declared native CI interop selections inside a prepared Nix environment.

This runner does not install dependencies or infer missing scenario coverage. It
executes every case in a requested lane and records every exit status. A passing
case means the existing test command passed, not that every runtime test executed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SELECTOR_PREFIXES = ("MPP_HARNESS_", "X402_HARNESS_", "MPP_CONFORMANCE_")
CASE_INPUTS = ("PAYMENT_CHANNELS_PROGRAM_SO", "PAYMENT_CHANNELS_PROGRAM_ID", "SURFPOOL_DATASOURCE_RPC_URL", "HARNESS_ONCHAIN")
SWIFT_GROUPS = {
    "standard": {
        "swift-run-swift-cross-sdk-conformance-vectors-d83aa553",
        "swift-run-swift-client-harness-smoke-against-typescript-server-e2804a05",
        "swift-run-swift-client-harness-smoke-against-rust-server-acb7f5c5",
    },
    "exact": {"swift-run-swift-x402-client-harness-against-rust-x402-server-36f27d15"},
    "upto": {"swift-run-swift-x402-upto-client-harness-against-rust-x402-upto-server-13c1cdbc"},
}


def select_group(cases: list[dict[str, Any]], lane: str | None, group: str | None) -> list[dict[str, Any]]:
    if group is None:
        return cases
    if lane != "swift" or group not in SWIFT_GROUPS:
        raise ValueError("groups require the swift lane and standard, exact, or upto")
    ids = [case["id"] for case in cases]
    partition = [case_id for members in SWIFT_GROUPS.values() for case_id in members]
    if len(partition) != len(set(partition)) or set(ids) != set(partition):
        raise ValueError("Swift groups must partition every declared Swift case exactly once")
    return [case for case in cases if case["id"] in SWIFT_GROUPS[group]]


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def case_environment(case: dict[str, Any], cwd: Path) -> dict[str, str]:
    inherited = dict(os.environ)
    environment = {
        key: value
        for key, value in inherited.items()
        if not key.startswith(SELECTOR_PREFIXES) and key not in CASE_INPUTS
    }
    environment.setdefault("CI", "true")
    environment.update(case["env"])
    for name, spec in case.get("runtime_env", {}).items():
        value = inherited.get(spec["source"], spec.get("default", ""))
        if spec.get("required") and not value:
            raise ValueError(f"{name} is required for case {case['id']}")
        if spec.get("kind") == "file" and value:
            artifact = Path(value).expanduser()
            if not artifact.is_absolute():
                artifact = cwd / artifact
            if not artifact.is_file():
                raise ValueError(f"{name} must point to an existing file")
            value = str(artifact.resolve())
        environment[name] = value
    return environment


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def run_case(case: dict[str, Any], results_dir: Path, timeout: float | None) -> dict[str, Any]:
    started = time.monotonic()
    result: dict[str, Any] = {
        "id": case["id"],
        "lane": case["lane"],
        "platform": case["platform"],
        "argv": case["argv"],
        "working_directory": case["working_directory"],
        "sources": case["sources"],
        "started_at": timestamp(),
        "status": "failed",
        "exit_code": None,
        # Runtime input values, including RPC credentials, are never recorded.
        "runtime_input_names": sorted(case.get("runtime_env", {})),
    }
    process: subprocess.Popen[bytes] | None = None
    print(f"\n==> {case['id']}", flush=True)
    try:
        platform = "darwin" if sys.platform == "darwin" else "linux" if sys.platform.startswith("linux") else sys.platform
        if platform != case["platform"]:
            raise ValueError(f"case requires {case['platform']}; current platform is {platform}")
        cwd = ROOT / case["working_directory"]
        if not cwd.is_dir():
            raise ValueError(f"working directory is missing: {case['working_directory']}")
        environment = case_environment(case, cwd)
        process = subprocess.Popen(case["argv"], cwd=cwd, env=environment, start_new_session=True)
        result["exit_code"] = process.wait(timeout=timeout)
        result["status"] = "passed" if result["exit_code"] == 0 else "failed"
    except subprocess.TimeoutExpired:
        result["error"] = f"case exceeded the configured {timeout:g}s timeout"
        result["exit_code"] = 124
    except KeyboardInterrupt:
        result["error"] = "interrupted"
        result["exit_code"] = 130
        result["status"] = "cancelled"
    except (OSError, ValueError) as error:
        result["error"] = str(error)
    finally:
        if process is not None:
            terminate(process)
        result["finished_at"] = timestamp()
        result["duration_seconds"] = round(time.monotonic() - started, 3)
        write_json(results_dir / f"{case['id']}.json", result)
    if result.get("error"):
        print(f"{case['id']}: {result['error']}", file=sys.stderr, flush=True)
    print(f"<== {case['id']}: {result['status']} ({result['duration_seconds']}s)", flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", nargs="?", help="lane declared in nix/interop-cases.json")
    parser.add_argument("--list", action="store_true", help="print case IDs and lanes without running tests")
    parser.add_argument("--results-dir", type=Path, default=ROOT / ".nix-results" / "interop")
    parser.add_argument("--timeout", type=float, help="optional per-case time limit in seconds")
    parser.add_argument("--group", default=os.environ.get("NIX_INTEROP_GROUP") or None,
                        help="Swift case group: standard, exact, or upto")
    args = parser.parse_args()
    if args.timeout is not None and args.timeout <= 0:
        parser.error("--timeout must be positive")
    manifest = json.loads((ROOT / "nix" / "interop-cases.json").read_text(encoding="utf-8"))
    all_cases = manifest["cases"]
    if not all_cases or len({case["id"] for case in all_cases}) != len(all_cases):
        parser.error("case manifest must contain nonempty, unique case IDs")
    lanes = sorted({case["lane"] for case in all_cases})
    if args.lane is not None and args.lane not in lanes:
        parser.error(f"unknown lane {args.lane!r}; choose from: {', '.join(lanes)}")
    if not args.list and args.lane is None:
        parser.error("a lane is required unless --list is used")
    cases = [case for case in all_cases if args.lane is None or case["lane"] == args.lane]
    try:
        cases = select_group(cases, args.lane, args.group)
    except ValueError as error:
        parser.error(str(error))
    if not cases:
        parser.error("selection contains zero cases")
    if args.list:
        print(json.dumps([{"id": case["id"], "lane": case["lane"], "platform": case["platform"]} for case in cases], indent=2))
        return 0
    results = []
    for case in cases:
        result = run_case(case, args.results_dir, args.timeout)
        results.append(result)
        if result["status"] == "cancelled":
            break
    summary = {
        "lane": args.lane,
        "group": args.group,
        "baseline_commit": manifest["baseline_commit"],
        "selected_cases": len(cases),
        "executed_cases": len(results),
        "passed_cases": sum(result["status"] == "passed" for result in results),
        "failed_cases": sum(result["status"] == "failed" for result in results),
        "cancelled_cases": sum(result["status"] == "cancelled" for result in results),
        "results": results,
        "finished_at": timestamp(),
    }
    summary["status"] = "passed" if len(results) == len(cases) and all(result["status"] == "passed" for result in results) else "failed"
    suffix = f"-{args.group}" if args.group else ""
    write_json(args.results_dir / f"{args.lane}{suffix}-summary.json", summary)
    print(f"\n{args.lane}: {summary['passed_cases']}/{len(cases)} cases passed; results: {args.results_dir}", flush=True)
    if summary["cancelled_cases"]:
        return 130
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
