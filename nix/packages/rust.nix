{ pkgs, craneLib, htmlAssets, ... }:
let
  inherit (pkgs) lib;
  cargoLock = ../locks/rust-Cargo.lock;
  lockPackages = (builtins.fromTOML (builtins.readFile cargoLock)).package;
  hashes = builtins.fromJSON (builtins.readFile ./rust-hashes.json);
  # Crane keys git hashes by the complete Cargo source URL. The existing
  # nixpkgs lock importer keys the same checkout hashes by package/version.
  outputHashes = builtins.listToAttrs (map (package: {
    name = package.source;
    value = hashes."${package.name}-${package.version}";
  }) (builtins.filter (package:
    lib.hasPrefix "git+" (package.source or "")
    && hashes ? "${package.name}-${package.version}") lockPackages));
  gitPackages = builtins.filter (package:
    lib.hasPrefix "git+" (package.source or "")) lockPackages;
  rustRoot = toString ../../rust;
  rustSource = lib.cleanSourceWith {
    src = ../../rust;
    name = "paykit-rust-source";
    filter = path: type:
      let relative = lib.removePrefix "${rustRoot}/" (toString path);
      in lib.cleanSourceFilter path type
        && !(type == "directory" && baseNameOf path == "target") && (
        type == "directory"
        || baseNameOf path == "Cargo.toml"
        || baseNameOf path == "build.rs"
        || lib.hasPrefix ".cargo/" relative
        || relative == "README.md"
        # Cargo validates declared targets even for a binary-only build. Keep
        # each workspace crate intact, including tests, benches, examples,
        # build scripts and their non-Rust inputs. Crane's dummy source still
        # isolates dependency compilation from these real source contents.
        || lib.hasPrefix "crates/" relative
      );
  };
  cargoVendorDir = craneLib.vendorCargoDeps {
    inherit cargoLock outputHashes;
  };
  commonArgs = {
    src = rustSource;
    inherit cargoLock cargoVendorDir;
    version = "0.1.0";
    strictDeps = true;
    doCheck = false;
    # Preserve native harness/playground dev builds. Coverage remains a
    # separately instrumented runtime job and never consumes these artifacts.
    CARGO_PROFILE = "dev";
    CARGO_INCREMENTAL = "0";
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ];
    postPatch = ''
      cp ${cargoLock} Cargo.lock
    '';
    postInstall = ''
      if [ -d target/cargo-timings ]; then
        mkdir -p "$out/share/paykit-cargo-timings"
        cp target/cargo-timings/*.html "$out/share/paykit-cargo-timings/"
      fi
    '';
    meta = {
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
  targetArgs = name: flags: commonArgs // {
    pname = name;
    cargoExtraArgs = "--locked ${flags}";
    cargoBuildExtraArgs = "--timings";
  };
  harnessArgs = targetArgs "paykit-rust-harness" "--package paykit-harness-bins --bins";
  # Match the native command's virtual-workspace selection. Other default
  # members enable the kit's client feature, which the example needs for its
  # reqwest calls. Narrowing this to --package changes feature unification.
  playgroundArgs = (targetArgs "paykit-rust-playground-server"
    "--example payment_link_server --features axum") // {
      # Native workspace features enable openssl-src's vendored build. Its
      # Configure script requires Perl in both matching compilation stages.
      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.perl ];
    };
  dependencies = args: craneLib.buildDepsOnly (args // {
    # Compile just the matching targets, without an additional cargo check or
    # test compilation. Crane stubs workspace sources for this derivation, so
    # ordinary SDK/HTML source edits do not invalidate dependency artifacts.
    buildPhaseCargoCommand = ''
      cargoWithProfile build ${args.cargoExtraArgs} --timings
    '';
  });
  harnessDeps = dependencies harnessArgs;
  playgroundDeps = dependencies playgroundArgs;
  package = args: cargoArtifacts: craneLib.buildPackage (args // {
    inherit cargoArtifacts;
    postPatch = commonArgs.postPatch + ''
      mkdir -p crates/kit/src/mpp/server/html
      cp ${htmlAssets}/rust/crates/kit/src/mpp/server/html/template.gen.html \
        crates/kit/src/mpp/server/html/template.gen.html
      cp ${htmlAssets}/rust/crates/kit/src/mpp/server/html/service_worker.gen.js \
        crates/kit/src/mpp/server/html/service_worker.gen.js
    '';
  });
in
assert lib.all (package: outputHashes ? "${package.source}") gitPackages;
{
  # Build artifacts only. SDK assertions and runtime interop remain fresh jobs.
  rust-harness = package harnessArgs harnessDeps;
  rust-playground-server = package playgroundArgs playgroundDeps;
  # These are build dependencies, not runtime closure dependencies. Cache them
  # explicitly so source edits can reuse compiled third-party crates.
  rust-harness-deps = harnessDeps;
  rust-playground-deps = playgroundDeps;
}
