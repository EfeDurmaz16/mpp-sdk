# Experimental Nix CI

This fork experiment runs the existing TypeScript, Rust, Go, Python, Ruby, Lua,
PHP, Kotlin and Swift checks through pinned Nix environments. The existing
GitHub Actions workflows remain the comparison. This is a draft experiment,
not a recommendation to replace required checks or a claim of faster CI.

The baseline is upstream commit `c294f8903f18efc746584e3cc2961d6033b8365c`.
The fork PR targets `experiment/nix-ci-baseline`; the fork's `main` is unchanged.
The optional workflow runs only on `EfeDurmaz16/mpp-sdk`'s `experiment/nix-ci`
branch. It has read-only repository permissions and does not publish packages.

## What changes

- `flake.lock` pins Nixpkgs. `toolchains.nix` selects each runtime and compiler.
- Separate Nix packages build the HTML assets, TypeScript SDKs, harness
  dependencies, six Rust adapters, two Go adapters and localnet SBF program.
- The shared build jobs export their runtime closures. Consumer jobs verify
  the artifact against a digest supplied separately by the producer, then
  import it into the disposable runner's Nix store. No external cache account
  or paid infrastructure is needed.
- `ci-lanes.json` defines 27 SDK, interop, browser and demo lanes. The interop
  manifest preserves 51 native workflow selections as 30 distinct cases.
  These are command selections, not counts of test assertions.
- The TS harness accepts an optional `PAY_KIT_HARNESS_COMMANDS` JSON map to run
  already-built adapters. Normal commands are unchanged when it is absent.

Tests execute on every app invocation. Their success is not cached. Shared
build outputs are cacheable; live RPC state, service startup and test outcomes
are runtime inputs and observations.

## Run a lane

With Nix and the `nix-command` and `flakes` features enabled, run from the repo:

```sh
nix flake check --no-build --all-systems --no-update-lock-file
nix run .#unit-go
nix run .#unit-python
nix run .#interop-go
nix run .#playground-typescript
nix run .#unit-swift # macOS
```

`nix flake check --no-build` validates definitions; it does not execute the SDK
tests. Use the named apps for those checks. Supported CI systems are
`x86_64-linux` and `aarch64-darwin`.

Linux builds the SBF program once. The same verified `.so` is supplied to the
Linux and macOS interop jobs. For local macOS program-backed interop, supply a
verified Linux-built artifact through `PAYMENT_CHANNELS_PROGRAM_SO`.

Each invocation writes `.nix-results/` with timings, exit status and the existing
coverage reports. Build jobs also record an initial-store build and a repeat
using the same store. Equal output paths and a fast repeat establish reuse in
that store, not an end-to-end improvement over native CI.

## Explicit boundaries

| Area | Current experiment |
| --- | --- |
| Shared HTML, TS, Rust, Go and SBF outputs | Nix derivations with fixed dependency inputs |
| Python, Ruby, PHP, Lua, Gradle dependencies | Downloaded by their existing package managers inside Nix environments |
| Tests and browser downloads | Fresh runtime commands; not sandboxed Nix checks |
| Swift SDK and harness | Darwin lane using Nix Swift and SwiftPM |
| iOS demo | Host Xcode and iOS Simulator SDK remain required |
| Android demo | Host Android SDK 34 and build-tools 34.0.0 remain required |
| RPC endpoint | Optional existing fork secret is forwarded to the same checks; public fallback when absent |
| Persistent project binary cache | Not configured; sharing currently covers jobs in the same run |

This is full test orchestration through Nix, not fully hermetic packaging of
every ecosystem. It does not change skip policies, add missing protocol
vectors, enforce repository merge rules or repair SDK behavior.

Some compiler patch versions differ from native CI. The workflow records the
exact versions. pnpm 11.13.0, Gradle 9.5.1 and golangci-lint 2.12.2 preserve the
existing selections. Nixpkgs supplies Node 22.23.3 and Go 1.26.8. The experiment
uses a committed Rust dependency lock where native CI resolves dependencies.
Redis currently comes from the pinned Nixpkgs revision; native CI uses Redis 7.
Treat these differences as comparison variables, not evidence of a speedup.

Swift uses macOS 15 rather than native CI's moving `macos-latest`. A scoped
library path works around this Nixpkgs pin's missing Swift Span back-deployment
rpath, fixed upstream in Nixpkgs PR #568774. The iOS demo invokes host Xcode in
a clean environment so Nix's compiler and linker settings cannot replace
Xcode's selected toolchain.

The same pin builds Swift Testing for macOS 14 by default. Its package is
rebuilt for the SDK's existing macOS 13 target, while the Swift compiler and
SwiftPM inputs remain unchanged. The SDK's platform support and test assertions
are not raised or disabled to accommodate the package.

pnpm's implicit dependency verification is disabled for prepared workspaces:
version 11.13 otherwise reinstalls dependencies after a directory move and can
overwrite Nix's native-binary patches. Explicit dependency installs still run
where the lane requires them.

## Refresh build inputs

Fixed fetcher hashes live next to the package expressions. When changing a
lockfile, use the corresponding fetcher target, inspect the fetched input and
update its hash. Rebuild the package and its consuming test lane afterward:

```sh
nix build .#html-npm-deps
nix build .#typescript-pnpm-deps
nix build .#harness-pnpm-deps
nix build .#rust-harness
nix build .#go-client .#go-server
nix build .#payment-channels # Linux
```

The SBF recipe fixes the source revision, treasury patch, Agave driver, SDK,
platform-tools v1.52 and `--arch v1`. It excludes generated deployment keypairs
from the reusable output.

## Evaluation

Before considering adoption, compare the same source revision and runner class:

1. Check which native and Nix test cases actually ran, including skipped cases.
2. Separate packaging failures from failures inside SDK assertions.
3. Compare total job minutes and critical-path duration, including artifact
   export, download and import overhead.
4. Measure cold and warm builds separately. Repeat enough times to distinguish
   cache behavior from RPC and runner variation.
5. Keep or remove the experiment based on the measured benefit and maintenance
   work. A green Nix definition check alone is not an adoption criterion.

Rollback is to stop running this optional branch workflow. The native CI
definitions and default harness commands remain available throughout.
