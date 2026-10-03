{ pkgs, toolchains, ... }:
let
  inherit (pkgs) lib;
  sourceRoot = ../..;
  swiftCompiler = builtins.elemAt toolchains.tools.swift 0;
  swiftPackageManager = builtins.elemAt toolchains.tools.swift 1;

  # Keep the root manifest's declared target directories, including tests, so
  # SwiftPM can validate the package graph without building or running tests.
  sourceFor = adapter: lib.cleanSourceWith {
    src = sourceRoot;
    name = "paykit-swift-${if adapter == null then "conformance" else adapter}-source";
    filter = path: type:
      let
        relative = lib.removePrefix "${toString sourceRoot}/" path;
        trees = [ "swift/Sources" "swift/Tests" ]
          ++ lib.optional (adapter != null) "harness/${adapter}";
        selected = path == toString sourceRoot
          || relative == "Package.swift"
          || (type == "directory" && builtins.elem relative
            ([ "swift" ] ++ lib.optional (adapter != null) "harness"))
          || builtins.any (tree: relative == tree
            || lib.hasPrefix "${tree}/" relative) trees;
      in lib.cleanSourceFilter path type && selected
        && !(builtins.elem (builtins.baseNameOf path) [ ".build" ".swiftpm" ]);
  };

  executable = { adapter ? null, product, profile ? "debug" }:
    pkgs.stdenv.mkDerivation {
      pname = "paykit-${if adapter == null then "swift-conformance" else adapter}";
      version = "0.1.0";
      src = sourceFor adapter;
      # Our wrapped SwiftPM is a symlinkJoin; include its setup hook explicitly
      # instead of relying on propagation through the customized wrapper.
      nativeBuildInputs = toolchains.tools.swift ++ [
        pkgs.swiftPackages.swiftpmHook
        pkgs.makeWrapper
        # SwiftPM applies debug entitlements using an ad-hoc codesign identity.
        # Pure Darwin builds cannot discover the runner's /usr/bin/codesign.
        pkgs.darwin.sigtool
      ];
      # Match the pinned Nixpkgs signingUtils recipe; sigtool needs this helper
      # and honors its absolute path rather than relying on host tool lookup.
      CODESIGN_ALLOCATE = "${pkgs.darwin.cctools}/bin/${pkgs.darwin.cctools.targetPrefix}codesign_allocate";
      strictDeps = true;
      dontConfigure = true;
      doCheck = false;
      enableParallelBuilding = true;
      swiftpmBuildConfig = profile;
      swiftpmFlags = [ "--product" product ];
      inherit (toolchains.environment) DYLD_LIBRARY_PATH;

      # The pinned Nixpkgs SwiftPM hook supplies the module-cache path and
      # --disable-sandbox inside Nix's build sandbox. No host Xcode is selected.
      preBuild = ''
        ${lib.optionalString (adapter != null) "cd harness/${adapter}"}
        appendToVar swiftpmFlags --cache-path "$TMPDIR/swiftpm-cache" \
          --config-path "$TMPDIR/swiftpm-config" \
          --security-path "$TMPDIR/swiftpm-security"
      '';
      installPhase = ''
        runHook preInstall
        binary_directory="$(swiftpmBinPath)"
        install -Dm755 "$binary_directory/${product}" "$out/bin/${product}"
        # Preserve the existing Span back-deployment workaround and its runtime
        # store references when the immutable executable runs outside SwiftPM.
        wrapProgram "$out/bin/${product}" \
          --prefix DYLD_LIBRARY_PATH : "${toolchains.environment.DYLD_LIBRARY_PATH}"
        runHook postInstall
      '';
      meta = {
        description = "Pinned Swift executable for fresh PayKit interop checks";
        license = lib.licenses.mit;
        platforms = lib.platforms.darwin;
      };
    };

  adapters = {
    swift-client = executable {
      adapter = "swift-client";
      product = "SwiftHarnessClient";
    };
    swift-x402-client = executable {
      adapter = "swift-x402-client";
      product = "SwiftX402Client";
    };
    swift-x402-upto-client = executable {
      adapter = "swift-x402-upto-client";
      product = "SwiftX402UptoClient";
    };
    # Match harness/runners/swift.json's native release profile.
    swift-conformance = executable {
      product = "mpp-conformance";
      profile = "release";
    };
  };
in
adapters // {
  # Root these customized paths explicitly. A selective binary cache can omit
  # public compiler/SDK requisites while retaining Testing and helper changes.
  swift-compiler = swiftCompiler;
  swift-package-manager = swiftPackageManager;
  swift-harness = pkgs.symlinkJoin {
    name = "paykit-swift-harness";
    paths = builtins.attrValues adapters;
  };
}
