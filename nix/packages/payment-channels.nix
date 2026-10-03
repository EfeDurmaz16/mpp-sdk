{ pkgs, toolchains ? { } }:
let
  hashes = builtins.fromJSON (builtins.readFile ./payment-channels-hashes.json);
  revision = "0c07d5751c8972abf6a219570a3f39a72f46f879";
  agaveVersion = "3.1.11";
  toolsVersion = "1.52";
  src = pkgs.fetchurl {
    name = "payment-channels-${revision}.tar.gz";
    url = "https://codeload.github.com/solana-foundation/payment-channels/tar.gz/${revision}";
    hash = hashes.source;
  };

  # Only the build driver is retained from the release. No validator is built
  # or installed. v3.1.11 defaults to platform-tools v1.52, so version checking
  # does not contact the moving GitHub latest-release endpoint.
  buildSbf = pkgs.stdenv.mkDerivation {
    pname = "cargo-build-sbf-bin";
    version = agaveVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/anza-xyz/agave/releases/download/v${agaveVersion}/solana-release-x86_64-unknown-linux-gnu.tar.bz2";
      hash = hashes.agaveRelease;
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 bin/cargo-build-sbf "$out/bin/cargo-build-sbf"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/bin/cargo-build-sbf" --version
    '';
    meta.platforms = [ "x86_64-linux" ];
  };

  platformTools = pkgs.stdenv.mkDerivation {
    pname = "solana-platform-tools-bin";
    version = toolsVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/anza-xyz/platform-tools/releases/download/v${toolsVersion}/platform-tools-linux-x86_64.tar.bz2";
      hash = hashes.platformTools;
    };
    # The upstream archive contains llvm/ and rust/ directly.
    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a rust llvm "$out/"
      # Debugger binaries require host Python/LLDB integration and are not used
      # to compile or strip SBF programs.
      rm -f "$out"/llvm/bin/lldb* "$out"/llvm/lib/liblldb*
      rm -rf "$out"/llvm/lib/python*
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      "$out/rust/bin/cargo" --version
      "$out/rust/bin/rustc" --version
      "$out/rust/bin/rustc" --print target-list | grep -Fx 'sbpfv1-solana-solana'
      "$out/llvm/bin/llvm-objcopy" --version
    '';
    meta.platforms = [ "x86_64-linux" ];
  };

  sbfSdk = pkgs.stdenvNoCC.mkDerivation {
    pname = "solana-sbf-sdk";
    version = agaveVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/anza-xyz/agave/releases/download/v${agaveVersion}/sbf-sdk.tar.bz2";
      hash = hashes.sbfSdk;
    };
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/dependencies"
      cp -a . "$out/"
      ln -s ${platformTools} "$out/dependencies/platform-tools"
      # strip.sh sources env.sh, whose upstream bootstrap also downloads the
      # unrelated Criterion C test runner. Nix already supplies every build
      # dependency, so this SDK must never run that mutable installer.
      substituteInPlace "$out/env.sh" \
        --replace-fail '"$sbf_sdk"/scripts/install.sh' ':'
      rm "$out/scripts/install.sh"
      patchShebangs "$out/scripts"
      runHook postInstall
    '';
    meta.platforms = [ "x86_64-linux" ];
  };

  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "payment-channels-cargo-vendor";
    inherit src;
    hash = hashes.cargoVendor;
  };

  paymentChannels = pkgs.stdenv.mkDerivation {
    pname = "payment-channels-localnet-sbf";
    version = builtins.substring 0 12 revision;
    inherit src cargoDeps;
    patches = [ ../patches/payment-channels-treasury.patch ];
    nativeBuildInputs = [
      pkgs.rustPlatform.cargoSetupHook
      buildSbf
    ];
    dontConfigure = true;
    # Host ELF processing must never modify the SBF artifact.
    dontStrip = true;
    dontPatchELF = true;
    postPatch = ''
      grep -Fq 'declare_id!("CHNLxYvVA28MJP9PrFuDXccuoGXAx7jBacfLEkahyGsX")' \
        program/payment_channels/src/lib.rs
      grep -Fq '0xb0, 0x41, 0xd9, 0xd3, 0x37, 0xb7, 0x21, 0xbe' \
        program/payment_channels/src/constants.rs
      grep -Fq '0x7d, 0x5b, 0x7e, 0xda, 0x8c, 0xac, 0x89, 0xaa' \
        program/payment_channels/src/constants.rs
    '';
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export PATH="${platformTools}/rust/bin:$PATH"
      export RUSTC="${platformTools}/rust/bin/rustc"
      export CARGO_NET_OFFLINE=true
      export CARGO_TARGET_DIR="$PWD/target"
      cargo-build-sbf \
        --manifest-path program/payment_channels/Cargo.toml \
        --sbf-sdk ${sbfSdk} \
        --tools-version v${toolsVersion} \
        --arch v1 \
        --skip-tools-install \
        --no-rustup-override \
        -- --locked --offline
      test -s target/deploy/payment_channels.so
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm444 target/deploy/payment_channels.so "$out/lib/payment_channels.so"
      mkdir -p "$out/nix-support"
      printf '%s\n' '${revision}' > "$out/nix-support/source-revision"
      printf '%s\n' 'agave=${agaveVersion} platform-tools=v${toolsVersion} arch=v1' \
        > "$out/nix-support/toolchain"
      # cargo-build-sbf creates a random deployment keypair as a side effect.
      # It is neither needed by the harness nor part of this cached output.
      runHook postInstall
    '';
    passthru = {
      inherit cargoDeps platformTools buildSbf;
      programId = "CHNLxYvVA28MJP9PrFuDXccuoGXAx7jBacfLEkahyGsX";
      programSo = "${paymentChannels}/lib/payment_channels.so";
    };
    meta = {
      description = "Pinned localnet payment-channels SBF artifact for interoperability tests";
      homepage = "https://github.com/solana-foundation/payment-channels";
      license = pkgs.lib.licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  payment-channels = paymentChannels;
}
