# Experimental Nix CI

This fork runs the existing TypeScript, Rust, Go, Python, Ruby, Lua, PHP,
Kotlin and Swift checks through pinned Nix environments. Native workflows remain
available for comparison. This is an optional draft experiment, not a claim
that replacing the current CI is faster or cheaper.

The baseline is upstream commit `c294f8903f18efc746584e3cc2961d6033b8365c`.
The fork PR targets `experiment/nix-ci-baseline`; the fork's `main` is unchanged.
The workflow is restricted to `EfeDurmaz16/mpp-sdk`, normally runs on pushes to
`experiment/nix-ci`, and can be dispatched for controlled measurements. It has
read-only repository and Actions permissions and publishes no packages.

## Build outputs and fresh checks

`flake.lock` pins Nixpkgs and Crane. `toolchains.nix` selects tools, while
`packages/` defines reusable preparation. Existing SDK tests, live interop and
coverage commands execute outside package builds on every selected app
invocation. Reusing a binary does not reuse its previous test result.

| Output family | Responsibility |
| --- | --- |
| HTML and TypeScript | Generated assets and SDK runtime exports are separate from browser/unit dependency trees. Audit prepares dependency metadata without compiling SDKs. |
| Rust | Immutable harness binaries and the Rust playground server consume separate compiled dependency outputs through Crane. |
| Swift | Immutable standard, exact and upto adapters plus the release conformance executable; customized compiler/SwiftPM outputs are retained separately. |
| Go | Immutable client and server adapters. |
| SBF | One Linux build supplies the same verified program artifact to Linux and macOS consumers. |

`rust-harness-deps` and `rust-playground-deps` are explicit cache roots because
compiled dependencies need not appear in a binary's runtime closure. They use
the corresponding package/features and dev profile, with incremental compilation
disabled. Ordinary SDK and generated HTML source edits can reuse these dependency
artifacts; final binaries still rebuild when their inputs change. Coverage uses
its own instrumented runtime Cargo target tree and does not consume them.

The harness accepts optional `PAY_KIT_HARNESS_COMMANDS` adapter commands and
`PAY_KIT_CONFORMANCE_COMMANDS` conformance commands for the prepared executables.
Default native commands remain available when these maps are absent. Swift
interop consumers run the immutable executables without installing the Swift
compiler in their runtime shell. Swift unit tests still use SwiftPM with fresh
coverage instrumentation.

## Scheduling and case preservation

`ci-lanes.json` defines 27 logical lanes. The workflow expands these to **36
primary jobs**, excluding the optional Rust diagnostic:

| Job family | Count | Dependencies and split |
| --- | ---: | --- |
| Plan | 1 | Evaluate definitions and matrices. |
| Units | 14 | TypeScript splits into lint/format, typecheck, tests/coverage and integration; the other unit lanes stay separate. |
| Shared producers | 2 | Linux and Darwin start after plan, concurrently with SBF. |
| SBF | 1 | Build the shared Linux program artifact. |
| Linux interop | 8 | Wait for shared Linux and SBF. |
| Swift interop | 3 | Standard, exact and upto groups wait for shared Darwin and SBF. |
| Browser | 5 | Wait for shared Linux; Rust prepares its own server/dependency outputs. |
| Mobile demos | 2 | Start after plan with explicit host SDK requirements. |

The Darwin producer has three consumers, so preparation can overlap SBF and the
three Swift test groups. Producer cache saving still belongs to the prerequisite
job and must count toward the consumer's wait. Splitting jobs adds runner setup
and transfer costs; lower wall time is an outcome to measure.

`interop-cases.json` preserves 51 native workflow selections as 30 distinct
command cases. Swift partitions its existing five cases as three standard,
one exact and one upto case. These are command counts, not assertion counts.
Assertions, selectors, coverage floors and existing skip policies are preserved.

Linux interop and browser consumers receive separately selected runtime
archives. Darwin consumers receive the shared Darwin runtime archive. Consumers
verify repository/run/attempt/commit identity and a manifest digest supplied
separately by the producer before importing. The SBF digest is also verified
before execution. Intermediate Rust compilation artifacts and custom Swift
build tools stay in producer caches, outside these runtime transfer selections.

## Run a lane or comparison

With Nix and the `nix-command` and `flakes` features enabled, run from the repo:

```sh
nix flake check --no-build --all-systems --no-update-lock-file
nix run .#unit-go
nix run .#unit-python
nix run .#interop-go
nix run .#playground-rust
nix run .#unit-swift # macOS
NIX_TYPESCRIPT_GATE=typecheck nix run .#unit-typescript
NIX_INTEROP_GROUP=exact nix run .#interop-swift # macOS
```

Without a gate/group selector, the named TypeScript or Swift app runs all its
existing gates/cases. `nix flake check --no-build` validates definitions and does
not execute SDK tests. Supported CI systems are `x86_64-linux` and
`aarch64-darwin`. Local macOS program-backed interop requires a verified
Linux-built artifact in `PAYMENT_CHANNELS_PROGRAM_SO`.

Manual workflow inputs are `cache_mode` (`packed`, `tar`, or `none`), `profile`
for file-count detail, and `diagnose_rust` for a separate compiler diagnostic.
Push runs use `packed`. Changing mode does not change test selections.

The optional `nix-rust-diagnostic.yml` workflow compares native and Nix-provided
Rust 1.98.1 on one Ubuntu runner, native first. It verifies identical source,
lockfile and generated HTML inputs, uses separate empty target directories,
fixes the dev profile and four Cargo jobs, and records compiler/linker/library
settings, Cargo timings and resource use. Fetch and tool setup are outside the
compile sample. Native libraries and linker environments remain measured
differences. This is one sample per compiler environment, not a sandboxed Nix
package comparison, a full-CI benchmark or a performance guarantee.

## Cache transports and scopes

Both transports use the current checkout's evaluated output contracts from
`scripts/outputs.py`. Keys include scope, platform, runner label, Nix version,
locked inputs and output/derivation identity.

| Mode | Behavior |
| --- | --- |
| `packed` | Default. Store compressed per-path NARs in GitHub Actions cache, omitting available public payloads. A compatible prefix hit imports only cached roots that match current evaluated roots. |
| `tar` | Comparison transport. Root the same selected outputs, garbage-collect unneeded store paths, then save the store/database snapshot. Only the exact v3 key is restored; old v1/v2 and prefix fallbacks are disabled. |
| `none` | Disable experimental Nix, Cargo and language persistence. Public Nix substitution and same-run artifact sharing still operate. |

| Output-cache scope | Selected roots |
| --- | --- |
| `shared-linux` | Eight runtime outputs plus `rust-harness-deps`. |
| `shared-darwin` | Five runtime outputs plus `rust-harness-deps`, `swift-compiler` and `swift-package-manager`. |
| `swift-tools` | Customized compiler and SwiftPM used by Swift unit tests. |
| `playground-rust` | Server executable and its compiled dependencies. |
| `unit-typescript` | HTML assets and full TypeScript unit preparation. |
| `unit-audit` | TypeScript audit dependency metadata/tree. |
| `unit-html` | Generated HTML assets. |

The customized Swift roots preserve the macOS 13 Swift Testing build, the
SwiftPM testing helper and coverage-tool links. Available public compiler/SDK
payloads can be obtained from the upstream cache instead of copied into every
packed snapshot. A public-cache lookup failure retains the payload locally.
NAR import still creates files; replacing tar does not guarantee lower I/O or
shorter job time.

Separate mutable caches retain the Rust unit lane's ordinary and instrumented
build trees, and compatible Python downloads/wheels, Ruby gems, Lua rocks, PHP
archives, Gradle dependencies and Go modules. These are keyed to lane/toolchain
and dependency inputs. Lua reuse is additionally bounded to a UTC week because
its dependencies lack a lockfile. Virtualenvs, test results and coverage reports
are not restored. Gradle task-output caching remains disabled. Tests and coverage
commands run again after hits.

All caches share the repository's existing storage allowance with native CI.
More scopes can increase misses or eviction pressure. The experiment does not
raise the budget or delete native caches; cache availability must be recorded
for each comparison rather than assumed from a previous successful save.

## Packed-cache trust boundary

Packed restore is restricted to disposable GitHub-hosted runners, the exact
fork and `refs/heads/experiment/nix-ci`, and `push` or `workflow_dispatch` events.
It rejects PR merge refs and self-hosted runners. It authenticates the restored
key/ref through GitHub's API and checks the recorded producer workflow,
run/attempt and head identity. The authorized branch cache is the trust boundary;
a manifest stored beside a payload is not an independent signature.

Current roots are checked against current derivation outputs. File hashes,
regular-file restrictions, NAR metadata/references and the selected closure are
validated before import, and the imported closure is checked afterward. Public
substitution uses normal Nix signature checks. Branch-trusted packed payloads
use a narrowly scoped privileged import from the validated local cache with
`--no-check-sigs`; persistent daemon trust, users and keys are unchanged. The
tar comparator has the snapshot action's restore behavior, not the packed
importer's per-payload validation. Neither transport is intended for an
untrusted cache writer or arbitrary external binary cache.

## Platform and runtime boundaries

| Area | Boundary |
| --- | --- |
| Python, Ruby, PHP, Lua and Gradle dependencies | Existing package managers still install inside pinned Nix environments. |
| Tests, browser downloads, Redis and validator/RPC state | Fresh runtime work, not hermetic Nix checks or cached success. |
| Swift SDK and harness | Nix Swift/SwiftPM on explicit `macos-26`. |
| iOS demo | Host Xcode and iOS Simulator SDK remain required. |
| Android demo | Host Android SDK 34 and build-tools 34.0.0 remain required. |
| RPC endpoint | Existing optional fork secret, with the same public fallback when absent. |

Compiler patch versions, dependency locking and Redis versions can differ from
native CI. Recorded tools, actual runner images and cache states are comparison
variables. This migration does not add missing protocol vectors, change merge
enforcement or fix SDK/network failures.

The pinned Swift tooling retains its scoped Span back-deployment library-path
workaround. Swift Testing is rebuilt for the SDK's existing macOS 13 target.
The missing SwiftPM 6.2.4 Darwin testing helper is compiled from its pinned source,
and the assembled toolchain includes matching `llvm-cov` and `llvm-profdata`.
The iOS demo invokes host Xcode in a clean environment. These adaptations do not
raise SDK platform requirements or disable assertions.

Prepared pnpm workspaces disable implicit dependency verification, which would
otherwise reinstall after staging and replace Nix's native-binary patches.
Explicit installs still run where required. Staging copies only selected trees
and changes permissions only on copied files, rather than traversing the entire
checkout repeatedly.

## Measurement and adoption

`.nix-results/` records command durations, exit status, output identities,
closure paths/bytes and existing coverage reports. `profile=true` also counts
files/directories/symlinks in selected roots. Command timing records include
child CPU/RSS metadata without dumping the process environment. Producer
initial-store and same-store repeats demonstrate local reuse, not complete CI
performance.

The earlier tar-based graph at `43fab772` took **17m05s** on its final three-cache-hit
run, versus **8m45s** for the same-tree native workflow family with mixed caches:
[historical Nix attempt](https://github.com/EfeDurmaz16/mpp-sdk/actions/runs/37044570679/attempts/3),
[native CI](https://github.com/EfeDurmaz16/mpp-sdk/actions/runs/37044578021) and
[native Harness](https://github.com/EfeDurmaz16/mpp-sdk/actions/runs/37044578056).
Those observations motivated this design. They do not measure the current
packed transport, split outputs or 36-job graph.

Compare full job windows and summed job durations, including producer builds,
cache save/restore and artifact transfer. Summed elapsed job seconds are not CPU
seconds or a billing estimate. Measure cold, exact-head warm, source-change,
lock/toolchain-change and cache-unavailable behavior. Verify fresh coverage,
all expected command records and actual failure causes. Neither a faster cache
phase nor a green definition check alone justifies adoption.

Rollback is to stop the optional workflow. Native CI and default harness
commands remain available throughout.

## Refresh build inputs

Fixed fetcher hashes live beside package expressions. After lockfile changes,
inspect fetched inputs, update corresponding hashes, rebuild affected outputs
and rerun their consuming lanes:

```sh
nix build .#html-npm-deps .#typescript-pnpm-deps .#harness-pnpm-deps
nix build .#rust-harness-deps .#rust-harness
nix build .#rust-playground-deps .#rust-playground-server
nix build .#swift-harness .#swift-compiler .#swift-package-manager # macOS
nix build .#go-client .#go-server
nix build .#payment-channels # Linux
```

The SBF recipe fixes the source revision, treasury patch, Agave driver, SDK,
platform-tools v1.52 and `--arch v1`. Generated deployment keypairs are excluded
from its reusable output.
