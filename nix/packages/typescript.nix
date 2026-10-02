{ pkgs, toolchains }:
let
  inherit (pkgs) lib;
  inherit (toolchains) nodejs pnpm;
  hashes = builtins.fromJSON (builtins.readFile ./typescript-hashes.json);

  # Language-scoped inputs keep an unrelated SDK edit out of these builds.
  source = name: directory: lib.cleanSourceWith {
    inherit name;
    src = directory;
    filter = path: type:
      !(builtins.elem (baseNameOf path) [
        "node_modules" "dist" "coverage" ".git" "test-results"
        "playwright-report" "external"
      ]);
  };
  htmlSource = source "pay-kit-html-source" ../../html;
  typescriptSource = source "pay-kit-typescript-source" ../../typescript;
  manifestSource = root: files: lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions files;
  };
  typescriptManifests = manifestSource ../../typescript [
    ../../typescript/package.json
    ../../typescript/pnpm-lock.yaml
    ../../typescript/pnpm-workspace.yaml
    ../../typescript/.npmrc
    ../../typescript/.x402-vendor
    ../../typescript/packages/mpp/package.json
    ../../typescript/packages/pay-kit/package.json
  ];
  harnessManifests = manifestSource ../.. [
    ../../harness/package.json
    ../../harness/pnpm-lock.yaml
    ../../harness/pnpm-workspace.yaml
    ../../typescript/packages/mpp/package.json
    ../../typescript/packages/pay-kit/package.json
  ];

  htmlDeps = pkgs.fetchNpmDeps {
    name = "pay-kit-html-npm-deps";
    src = manifestSource ../../html [
      ../../html/package.json
      ../../html/package-lock.json
    ];
    hash = hashes.html;
  };
  typescriptDeps = pkgs.fetchPnpmDeps {
    pname = "pay-kit-typescript";
    version = "0.0.0-experiment";
    src = typescriptManifests;
    inherit pnpm;
    fetcherVersion = 4;
    hash = hashes.typescript;
  };
  harnessDeps = pkgs.fetchPnpmDeps {
    pname = "pay-kit-harness";
    version = "0.0.0-experiment";
    src = harnessManifests;
    sourceRoot = "source/harness";
    inherit pnpm;
    fetcherVersion = 4;
    hash = hashes.harness;
  };
  nativeInputs = [ nodejs pnpm pkgs.pnpmConfigHook ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.autoPatchelfHook ];
  nativeLibraries = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.stdenv.cc.cc.lib
  ];
  # utf-8-validate ships GNU and musl prebuilds in one package. Its loader
  # selects GNU on this target, but autoPatchelf scans both variants.
  pruneNonHostPrebuilds = directory:
    lib.optionalString (pkgs.stdenv.hostPlatform.libc == "glibc") ''
      find ${lib.escapeShellArg directory} -type f \
        -path '*/utf-8-validate/prebuilds/linux-*/utf-8-validate.musl.node' \
        -print -delete
    '';

  htmlAssets = pkgs.buildNpmPackage {
    pname = "pay-kit-html-assets";
    version = "0.0.0-experiment";
    outputs = [ "out" "dev" ];
    src = htmlSource;
    inherit nodejs;
    npmDeps = htmlDeps;
    # The generator deliberately writes language-specific sibling paths.
    preBuild = ''
      mkdir -p ../typescript/packages/mpp/src/server
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/html"
      # Generated assets and their source metadata do not require the HTML
      # generator's dependency tree on every interop runner.
      for path in package.json package-lock.json build.ts tsconfig.json src tests dist; do
        cp -a "$path" "$out/html/"
      done
      for language in rust go lua python typescript; do
        cp -a "../$language" "$out/$language"
      done
      # Browser jobs execute Playwright from this dependency tree. Keep it
      # separately selectable instead of adding it to the runtime closure.
      mkdir -p "$dev/html"
      cp -a node_modules "$dev/html/"
      runHook postInstall
    '';
  };

  typescriptSdk = pkgs.stdenv.mkDerivation {
    pname = "pay-kit-typescript-sdk";
    version = "0.0.0-experiment";
    outputs = [ "out" "dev" ];
    src = typescriptSource;
    pnpmDeps = typescriptDeps;
    nativeBuildInputs = nativeInputs;
    buildInputs = nativeLibraries;
    strictDeps = true;
    buildPhase = ''
      runHook preBuild
      cp ${htmlAssets}/typescript/packages/mpp/src/server/html-assets.gen.ts \
        packages/mpp/src/server/html-assets.gen.ts
      ${pruneNonHostPrebuilds "node_modules"}
      ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "autoPatchelf node_modules"}
      pnpm --filter @solana/mpp build
      pnpm --filter @solana/pay-kit build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      for package in mpp pay-kit; do
        destination="$out/typescript/packages/$package"
        mkdir -p "$destination"
        # Match the SDK's exported package content. Source and source maps
        # remain available, but local workspace dependency links and historic
        # npm archives are not required by file: harness installations.
        cp -a "packages/$package/package.json" "packages/$package/src" \
          "packages/$package/dist" "$destination/"
        for metadata in README.md LICENSE LICENSE.md; do
          if [[ -f "packages/$package/$metadata" ]]; then
            cp -a "packages/$package/$metadata" "$destination/"
          fi
        done
      done
      # Unit gates need the full source/configuration tree, workspace links,
      # native addons and tooling. Keeping this output separate preserves
      # lint/typecheck/test behavior without shipping it to every harness.
      mkdir -p "$dev/typescript"
      cp -a . "$dev/typescript/"
      runHook postInstall
    '';
    dontStrip = true;
  };

  typescriptAudit = pkgs.stdenv.mkDerivation {
    pname = "pay-kit-typescript-audit-dependencies";
    version = "0.0.0-experiment";
    src = typescriptManifests;
    pnpmDeps = typescriptDeps;
    nativeBuildInputs = nativeInputs;
    buildInputs = nativeLibraries;
    strictDeps = true;
    # Audit consumes package metadata and installed dependency graphs. It
    # neither embeds generated HTML nor imports compiled SDK exports.
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      ${pruneNonHostPrebuilds "node_modules"}
      mkdir -p "$out/typescript"
      cp -a . "$out/typescript/"
      runHook postInstall
    '';
    dontStrip = true;
  };

  harnessDependencies = pkgs.stdenv.mkDerivation {
    pname = "pay-kit-harness-dependencies";
    version = "0.0.0-experiment";
    src = harnessManifests;
    pnpmRoot = "harness";
    pnpmDeps = harnessDeps;
    nativeBuildInputs = nativeInputs;
    buildInputs = nativeLibraries;
    strictDeps = true;
    # file: SDK dependencies must contain the actual compiled packages before
    # pnpm copies them into its virtual store. Fetching only uses manifests.
    postPatch = ''
      cp -a ${typescriptSdk}/typescript/packages/. typescript/packages/
      chmod -R u+w typescript
    '';
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      ${pruneNonHostPrebuilds "harness/node_modules"}
      mkdir -p "$out/harness"
      cp -a harness/node_modules "$out/harness/"
      runHook postInstall
    '';
    dontStrip = true;
  };
in
{
  html-assets = htmlAssets;
  html-browser-deps = htmlAssets.dev;
  typescript-sdk = typescriptSdk;
  typescript-unit = typescriptSdk.dev;
  typescript-audit = typescriptAudit;
  harness-deps = harnessDependencies;
  # Separate fetcher targets allow dependency hashes to be refreshed without
  # compiling the SDKs or running any network-dependent interop tests.
  html-npm-deps = htmlDeps;
  typescript-pnpm-deps = typescriptDeps;
  harness-pnpm-deps = harnessDeps;
}
