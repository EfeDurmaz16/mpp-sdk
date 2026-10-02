{ pkgs, ... }:
let
  inherit (pkgs) lib;
  hashes = builtins.fromJSON (builtins.readFile ./rust-hashes.json);
  rustSource = lib.cleanSourceWith {
    src = ../../rust;
    name = "paykit-rust-source";
    filter = path: type:
      lib.cleanSourceFilter path type
      && !(builtins.elem (builtins.baseNameOf path) [ "target" "Cargo.lock" ]);
  };
in
{
  # Build artifacts only. SDK assertions and runtime interop remain separate jobs.
  rust-harness = pkgs.rustPlatform.buildRustPackage {
    pname = "paykit-rust-harness";
    version = "0.1.0";
    src = rustSource;

    cargoLock = {
      lockFile = ../locks/rust-Cargo.lock;
      outputHashes = hashes;
    };
    postPatch = ''
      cp ${../locks/rust-Cargo.lock} Cargo.lock
    '';

    # Match the existing harness build profile and build all six adapters once.
    buildType = "debug";
    cargoBuildFlags = [ "--package" "paykit-harness-bins" "--bins" ];
    doCheck = false;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.libiconv ];

    meta = {
      description = "Shared MPP and x402 Rust adapter binaries for the experimental CI";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  };
}
