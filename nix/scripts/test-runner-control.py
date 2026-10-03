#!/usr/bin/env python3
"""Opt-in same-host warmed Cargo/Nextest comparison; never changes CI defaults."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

PACKAGES = ["-p", "solana-pay-kit", "-p", "paykit-integration-tests"]
REGEX = "crates/integration-tests/|crates/harness-bins/|src/mpp/program/|src/x402/|src/generated/"
REDIS_TEST = "core::store::tests::redis_channel_store_roundtrip_and_atomic_watermark"


def listed_names(output):
    """Libtest terse output preserves the complete name before ': test'."""
    return {line[:-6] for line in output.splitlines() if line.endswith(": test")}


def check_parity(native, candidate):
    if native != candidate:
        missing = sorted(native.keys() - candidate.keys())
        added = sorted(candidate.keys() - native.keys())
        flags = sorted(key for key in native.keys() & candidate.keys()
                       if native[key] != candidate[key])
        raise RuntimeError(f"Test identity mismatch: missing={missing}, added={added}, ignored={flags}")
    if not native:
        raise RuntimeError("Empty test selection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    rust = root / "rust"
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not os.environ.get("PAY_KIT_TEST_REDIS_URL"):
        parser.error("PAY_KIT_TEST_REDIS_URL must point to the job-owned Redis fixture")
    if not (rust / "Cargo.lock").is_file():
        parser.error("Stage the committed Nix Cargo.lock before invoking this control")
    samples = []
    secrets = [value for key, value in os.environ.items()
               if value and (key == "SURFPOOL_DATASOURCE_RPC_URL"
                             or any(word in key for word in ("TOKEN", "SECRET", "PASSWORD")))]

    def sanitize(value):
        for secret in sorted(secrets, key=len, reverse=True):
            value = value.replace(secret, "[REDACTED]")
        return value

    def save():
        (out / "summary.json").write_text(json.dumps({
            "description": "Warmed CLI wall time includes Cargo validation and test discovery; no compiler speed claim",
            "samples": samples,
        }, indent=2) + "\n")

    def run(label, command):
        print(f"Running {label}", flush=True)
        start = time.perf_counter()
        result = subprocess.run(command, cwd=rust, text=True, capture_output=True)
        elapsed = time.perf_counter() - start
        (out / f"{label}.stdout").write_text(sanitize(result.stdout))
        (out / f"{label}.stderr").write_text(sanitize(result.stderr))
        samples.append({"label": label, "seconds": elapsed, "exit_code": result.returncode,
                        "command": command})
        save()
        if result.returncode:
            raise RuntimeError(f"{label} failed with exit {result.returncode}; inspect sanitized logs")
        return result.stdout

    version = run("nextest-version", ["cargo", "nextest", "--version"])
    if not version.startswith("cargo-nextest 0.9.146 "):
        raise RuntimeError("This experiment requires cargo-nextest 0.9.146")
    run("rustc-version", ["rustc", "-vV"])
    run("cargo-version", ["cargo", "--version"])
    # Build once before timed warm runs. --tests includes library and integration
    # targets; doctests receive separate additional validation below.
    build = run("prepare-test-binaries", ["cargo", "test", "--locked", *PACKAGES,
                 "--tests", "--no-run", "--message-format=json"])
    binaries = set()
    for line in build.splitlines():
        item = json.loads(line)
        if item.get("reason") == "compiler-artifact" and item.get("profile", {}).get("test"):
            if item.get("executable"):
                binaries.add(str(Path(item["executable"]).resolve()))
    candidate = json.loads(run("nextest-list", ["cargo", "nextest", "list", "--locked",
        *PACKAGES, "--tests", "--profile", "runner-control", "--run-ignored", "all",
        "--message-format=json"]))
    native_names = {}
    for index, binary in enumerate(sorted(binaries)):
        names = listed_names(run(f"native-list-{index}", [binary, "--list", "--format", "terse"]))
        ignored = listed_names(run(f"native-ignored-{index}",
                              [binary, "--list", "--format", "terse", "--ignored"]))
        native_names.update({(binary, name): name in ignored for name in names})
    candidate_names = {}
    for suite in candidate["rust-suites"].values():
        binary = str(Path(suite["binary-path"]).resolve())
        for name, case in suite["testcases"].items():
            if case["filter-match"]["status"] == "matches":
                candidate_names[(binary, name)] = case["ignored"]
    check_parity(native_names, candidate_names)
    (out / "identity-parity.json").write_text(json.dumps({
        "tests": len(native_names), "ignored": sum(native_names.values()),
        "identities": [{"binary": binary, "name": name, "ignored": ignored}
                       for (binary, name), ignored in sorted(native_names.items())],
    }, indent=2) + "\n")
    commands = {
        "cargo": ["cargo", "test", "--locked", *PACKAGES, "--tests"],
        "nextest": ["cargo", "nextest", "run", "--locked", *PACKAGES, "--tests",
                    "--profile", "runner-control", "--no-tests=fail"],
    }
    # AB/BA/AB bounds work and exposes some order effects without changing builds.
    for round_id, order in enumerate(("cargo nextest", "nextest cargo", "cargo nextest"), 1):
        for runner in order.split():
            run(f"warm-{round_id}-{runner}", commands[runner])
    run("nextest-coverage", ["cargo", "llvm-cov", "nextest", "--locked", *PACKAGES,
        "--profile", "runner-control", "--ignore-filename-regex", REGEX,
        "--json", "--output-path", str(out / "coverage.json")])
    coverage = json.loads((out / "coverage.json").read_text())["data"][0]["totals"]["lines"]["percent"]
    if coverage < 90.0:
        raise RuntimeError(f"Rust line coverage {coverage:.2f}% is below unchanged 90% floor")
    # Nextest omits docs; this is additional stable validation, not doc coverage.
    run("doctests", ["cargo", "test", "--locked", *PACKAGES, "--doc"])
    run("nextest-x402", ["cargo", "nextest", "run", "--locked", "-p", "solana-pay-kit",
        "--lib", "--profile", "runner-control", "--no-tests=fail", "x402"])
    run("nextest-redis", ["cargo", "nextest", "run", "--locked", "-p", "solana-pay-kit",
        "--features", "redis-store", "--lib", "--profile", "runner-control",
        "--no-tests=fail", "--", REDIS_TEST, "--exact"])
    run("cargo-fmt", ["cargo", "fmt", "--check"])
    medians = {runner: statistics.median(item["seconds"] for item in samples
        if item["label"].startswith("warm-") and item["label"].endswith(f"-{runner}"))
        for runner in commands}
    (out / "result.json").write_text(json.dumps({"coverage_percent": coverage,
        "test_identity_parity": True, "warm_cli_median_seconds": medians,
        "nextest_over_cargo_ratio": medians["nextest"] / medians["cargo"],
        "limitations": "Three same-host warmed CLI observations, AB/BA/AB order; no full-CI or cold-build speed claim",
    }, indent=2) + "\n")
    print(json.dumps(medians), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
