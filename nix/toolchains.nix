{ pkgs }:
let
  inherit (pkgs) lib;

  nodejs = pkgs.nodejs_22;
  pnpm = pkgs.pnpm_11.override {
    version = "11.13.0";
    hash = "sha256-hlx2vZERpFykH27u1AZ/8Ozf7p6sg6rSQXnIP/6+dZk=";
    nodejs-slim = pkgs.nodejs-slim_22;
  };

  go = pkgs.go_1_26;
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
  inherit nodejs pnpm go rust cargo java gradle python ruby bundler php composer lua;

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
    go = [ go pkgs.golangci-lint ];
    python = [ python pkgs.uv ];
    ruby = [ ruby bundler pkgs.openssl pkgs.libyaml ];
    php = [ php composer ];
    lua = [ lua pkgs.luajitPackages.luarocks pkgs.libsodium pkgs.openssl ];
    kotlin = [ java gradle ];
    swift = [ pkgs.swift pkgs.swiftpm ];
  };
}
