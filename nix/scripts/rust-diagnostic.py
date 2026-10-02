#!/usr/bin/env python3
"""Compare cold Rust compiler environments, not cached or sandboxed CI builds."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / ".nix-results/rust-diagnostic"
WORK = ROOT / ".nix-work/rust-diagnostic"
VERSION = "1.98.1"
BUILD = [
    "cargo", "build", "--locked", "--offline", "--profile", "dev", "--jobs", "4",
    "--example", "payment_link_server",
    "--features", "axum", "--timings",
]
# These explicit values match the playground package's dev build. Native
# libraries, compiler packaging and linker flags remain measured differences.
CONTROLLED = {
    "CARGO_INCREMENTAL": "0", "CARGO_BUILD_JOBS": "4", "CARGO_TERM_COLOR": "never",
    "CARGO_PROFILE_DEV_OPT_LEVEL": "0", "CARGO_PROFILE_DEV_DEBUG": "2",
    "CARGO_PROFILE_DEV_DEBUG_ASSERTIONS": "true",
    "CARGO_PROFILE_DEV_OVERFLOW_CHECKS": "true", "CARGO_PROFILE_DEV_LTO": "false",
    "CARGO_PROFILE_DEV_PANIC": "unwind", "CARGO_PROFILE_DEV_CODEGEN_UNITS": "256",
    "RUSTFLAGS": "", "CARGO_ENCODED_RUSTFLAGS": "",
}
ENV_KEYS = [
    *CONTROLLED, "CC", "CXX", "AR", "LD", "CFLAGS", "CXXFLAGS", "LDFLAGS",
    "NIX_CFLAGS_COMPILE", "NIX_LDFLAGS", "NIX_ENFORCE_PURITY",
    "NIX_HARDENING_ENABLE", "PKG_CONFIG_PATH", "OPENSSL_DIR",
    "OPENSSL_LIB_DIR", "OPENSSL_INCLUDE_DIR", "RUSTUP_TOOLCHAIN",
    "ImageOS", "ImageVersion", "RUNNER_ARCH", "RUNNER_OS",
]


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def output(command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True).strip()


def sources():
    paths = output(["git", "ls-files", "--", "rust"]).splitlines()
    paths += ["rust/Cargo.lock", "rust/crates/kit/src/mpp/server/html/template.gen.html",
              "rust/crates/kit/src/mpp/server/html/service_worker.gen.js"]
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in sorted(set(paths)) if (ROOT / name).is_file()}


def prepare():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("This compiler diagnostic requires the Ubuntu x86_64 runner")
    RESULTS.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    html = Path(output(["nix", "build", "--no-update-lock-file", "--no-link",
                        "--print-out-paths", ".#html-assets"]))
    shutil.copyfile(ROOT / "nix/locks/rust-Cargo.lock", ROOT / "rust/Cargo.lock")
    directory = Path("rust/crates/kit/src/mpp/server/html")
    (ROOT / directory).mkdir(parents=True, exist_ok=True)
    for name in ["template.gen.html", "service_worker.gen.js"]:
        shutil.copyfile(html / directory / name, ROOT / directory / name)
    cpu = json.loads(output(["lscpu", "--json"]))["lscpu"]
    cpu_fields = {"Architecture:", "CPU(s):", "On-line CPU(s) list:", "Vendor ID:",
                  "Model name:", "Thread(s) per core:", "Core(s) per socket:",
                  "Socket(s):", "CPU max MHz:", "CPU min MHz:"}
    memory = [line for line in Path("/proc/meminfo").read_text().splitlines()
              if line.startswith(("MemTotal:", "SwapTotal:"))]
    write(RESULTS / "inputs.json", {
        "head": output(["git", "rev-parse", "HEAD"]), "sources": sources(),
        "html_output": str(html), "preparation_seconds": time.monotonic() - started,
        "hardware": {"cpu": [row for row in cpu if row["field"] in cpu_fields],
                     "memory": memory, "kernel": platform.release()},
        "order": ["native", "nix"], "command": BUILD, "controlled_env": CONTROLLED,
        "scope": "Same-host cold compile; excludes fetch and tool setup; no target cache",
    })


def build(backend):
    inputs = json.loads((RESULTS / "inputs.json").read_text())
    if sources() != inputs["sources"]:
        raise SystemExit("Rust source or generated inputs changed before the sample")
    directory = RESULTS / backend
    directory.mkdir(exist_ok=False)
    cargo_home, target = WORK / backend / "cargo-home", WORK / backend / "target"
    cargo_home.mkdir(parents=True, exist_ok=False)
    target.mkdir(exist_ok=False)
    env = os.environ.copy()
    for key in ["RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER", "RUSTC", "RUSTDOC",
                "CARGO_BUILD_RUSTFLAGS", "CARGO_BUILD_RUSTC_WRAPPER",
                "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER"]:
        env.pop(key, None)
    env.update(CONTROLLED, CARGO_HOME=str(cargo_home), CARGO_TARGET_DIR=str(target))
    if backend == "native":
        env["RUSTUP_TOOLCHAIN"] = VERSION
    compiler = output(["rustc", "--version", "--verbose"], env)
    if f"release: {VERSION}\n" not in compiler + "\n":
        raise SystemExit(f"Expected Rust {VERSION}; got {compiler}")
    compiler_path = shutil.which("rustc", path=env["PATH"])
    if (backend == "nix") != compiler_path.startswith("/nix/store/"):
        raise SystemExit(f"Unexpected {backend} compiler path: {compiler_path}")
    tools = {"rustc": compiler, "cargo": output(["cargo", "--version", "--verbose"], env),
             "cc": output([env.get("CC", "cc"), "--version"], env),
             "ld": output([env.get("LD", "ld"), "--version"], env),
             "pkg-config": output(["pkg-config", "--version"], env),
             "openssl": output(["pkg-config", "--modversion", "openssl"], env)}
    sample = {"backend": backend, "command": BUILD, "head": inputs["head"],
              "sources": inputs["sources"], "compiler_path": compiler_path, "tools": tools,
              "environment": {key: env[key] for key in ENV_KEYS if key in env},
              "cargo_home": str(cargo_home), "target": str(target)}
    write(directory / "sample.json", sample)
    started = time.monotonic()
    with (directory / "fetch.log").open("w") as log:
        fetched = subprocess.run(["cargo", "fetch", "--locked"], cwd=ROOT / "rust",
                                 env=env, stdout=log, stderr=subprocess.STDOUT)
    sample.update(fetch_seconds=time.monotonic() - started, fetch_exit_code=fetched.returncode)
    write(directory / "sample.json", sample)
    if fetched.returncode:
        raise SystemExit(fetched.returncode)
    # Cargo may cache compiler discovery during fetch; no compiled target is reused.
    (target / ".rustc_info.json").unlink(missing_ok=True)
    if any(target.iterdir()):
        raise SystemExit("Target was not empty before the cold compiler sample")
    started = time.monotonic()
    with (directory / "build.log").open("w") as log:
        compiled = subprocess.run(["/usr/bin/time", "-v", "-o", str(directory / "resources.txt"),
                                   *BUILD], cwd=ROOT / "rust", env=env,
                                  stdout=log, stderr=subprocess.STDOUT)
    sample.update(compile_seconds=time.monotonic() - started, exit_code=compiled.returncode,
                  target_empty_before_build=True, source_unchanged=sources() == inputs["sources"])
    for timing in (target / "cargo-timings").glob("*.html"):
        shutil.copyfile(timing, directory / timing.name)
    write(directory / "sample.json", sample)
    print(json.dumps({key: sample[key] for key in ["backend", "fetch_seconds", "compile_seconds", "exit_code"]}))
    if not sample["source_unchanged"]:
        raise SystemExit("Rust source or lockfile changed during compilation")
    raise SystemExit(compiled.returncode)


def compare():
    samples = [json.loads((RESULTS / backend / "sample.json").read_text())
               for backend in ["native", "nix"]]
    native, nix = samples
    for key in ["head", "sources", "command"]:
        if native[key] != nix[key]:
            raise SystemExit(f"Cannot compare different {key}")
    if any({key: sample["environment"].get(key) for key in CONTROLLED} != CONTROLLED
           for sample in samples):
        raise SystemExit("Compiler samples did not preserve the controlled build settings")
    if any(sample["exit_code"] or not sample["source_unchanged"] for sample in samples):
        raise SystemExit("Both compiler samples must succeed on unchanged inputs")
    write(RESULTS / "comparison.json", {
        "native_compile_seconds": native["compile_seconds"],
        "nix_compile_seconds": nix["compile_seconds"],
        "nix_over_native_ratio": nix["compile_seconds"] / native["compile_seconds"],
        "scope": "One sample per environment, native first on the same host; no intrinsic Nix or full-CI speed claim",
    })
    print((RESULTS / "comparison.json").read_text())


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ["prepare", "native", "nix", "compare"]:
        raise SystemExit("usage: rust-diagnostic.py prepare|native|nix|compare")
    {"prepare": prepare, "compare": compare}.get(sys.argv[1], lambda: build(sys.argv[1]))()
