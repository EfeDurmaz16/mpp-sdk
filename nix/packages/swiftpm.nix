{ pkgs, swift }:
let
  # SwiftPM 6.2.4 declares this Darwin helper in Package.swift, but omits it from
  # its CMake build. Compile the unmodified helper from the same pinned source.
  helper = pkgs.stdenv.mkDerivation {
    pname = "swiftpm-testing-helper";
    inherit (pkgs.swiftpm) version src;
    nativeBuildInputs = [ swift ];
    strictDeps = true;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      swiftc -parse-as-library -swift-version 5 -O \
        -module-cache-path "$TMPDIR/module-cache" \
        Sources/swiftpm-testing-helper/Entrypoint.swift \
        -o swiftpm-testing-helper
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 swiftpm-testing-helper "$out/bin/swiftpm-testing-helper"
      runHook postInstall
    '';
  };
in
pkgs.symlinkJoin {
  name = "swiftpm-${pkgs.swiftpm.version}-with-testing-helper";
  paths = [ pkgs.swiftpm helper ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    # SwiftSDK.systemSwiftSDK honors this path before deriving one from argv[0].
    # Keep cached SwiftPM executables and avoid symlink-dependent helper lookup.
    for executable in ${pkgs.swiftpm}/bin/*; do
      wrapProgram "$out/bin/$(basename "$executable")" \
        --set SWIFTPM_CUSTOM_BIN_DIR "$out/bin"
    done
  '';
  meta = pkgs.swiftpm.meta;
}
