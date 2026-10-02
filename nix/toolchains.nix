{ pkgs }:
let
  inherit (pkgs) lib;

  nodejs = pkgs.nodejs_22;
  pnpm = (pkgs.pnpm_11.override {
    version = "11.13.0";
    hash = "sha256-hlx2vZERpFykH27u1AZ/8Ozf7p6sg6rSQXnIP/6+dZk=";
    nodejs-slim = pkgs.nodejs-slim_22;
  }).overrideAttrs {
    # pnpm 11.13 stores optional native modules under node_modules; newer releases
    # moved them into dist. Keep the Nixpkgs policy of removing bundled binaries.
    postUnpack = ''
      rm -rf package/dist/node_modules/@reflink/reflink-* package/dist/vendor
    '';
  };

  go = pkgs.go_1_26;
  # Preserve the native CI lint policy while using the current compiler packages.
  golangciLint = (pkgs.golangci-lint.override {
    buildGo127Module = pkgs.buildGo126Module;
  }).overrideAttrs (finalAttrs: {
    version = "2.12.2";
    src = pkgs.fetchFromGitHub {
      owner = "golangci";
      repo = "golangci-lint";
      tag = "v${finalAttrs.version}";
      hash = "sha256-qR7fp1x2S+EwEAcplRHTvA3jWwLr/XSiYKSZtAwkrNU=";
    };
    vendorHash = "sha256-AG5wtLwWLz55bdp1oi3cW+9O3yj1W1P7MV9zxym7Pb4=";
  });
  rust = pkgs.rustc;
  cargo = pkgs.cargo;
  java = pkgs.jdk17;
  gradle = pkgs.gradle-packages.mkGradle {
    version = "9.5.1";
    hash = "sha256-uvwUG2Ga1jUP2XX8kDFW3VwVGZjMiwWOjBBEq197Ax8=";
    defaultJava = java;
  };

  python = pkgs.python311;
  ruby = pkgs.ruby_3_3;
  bundler = pkgs.bundler.override { inherit ruby; };
  php = pkgs.php83.buildEnv {
    extensions = { enabled, all }: enabled ++ [ all.pcov ];
    extraConfig = "pcov.enabled=1";
  };
  composer = pkgs.php83Packages.composer.override { inherit php; };
  lua = pkgs.luajit;
in
{
  inherit nodejs pnpm go golangciLint rust cargo java gradle python ruby bundler php composer lua;

  # Runtime rock builds need both outputs; Nix separates headers from libraries.
  luaIncludeDir = "${lua}/include/luajit-2.1";
  sodiumIncludeDir = "${lib.getDev pkgs.libsodium}/include";
  sodiumLibraryDir = "${lib.getLib pkgs.libsodium}/lib";
  opensslIncludeDir = "${lib.getDev pkgs.openssl}/include";
  opensslLibraryDir = "${lib.getLib pkgs.openssl}/lib";

  tools = {
    common = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      git
      curl
      cacert
      jq
      unzip
      zip
      gnutar
      gzip
      pkg-config
      gnumake
      stdenv.cc
      python
    ];
    typescript = [ nodejs pnpm ];
    rust = with pkgs; [
      rust
      cargo
      rustfmt
      clippy
      cargo-llvm-cov
      llvmPackages.llvm
      openssl
      protobuf
    ];
    go = [ go golangciLint ];
    python = [ python pkgs.uv ];
    ruby = [ ruby bundler pkgs.openssl pkgs.libyaml ];
    php = [ php composer ];
    lua = [ lua pkgs.luajitPackages.luarocks pkgs.libsodium pkgs.openssl ];
    kotlin = [ java gradle ];
    swift = [ pkgs.swift pkgs.swiftpm ];
  };
}
