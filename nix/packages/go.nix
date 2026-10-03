{ pkgs, ... }:
let
  inherit (pkgs) lib;
  hashes = builtins.fromJSON (builtins.readFile ./go-hashes.json);
  repoRoot = ../..;
  buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_26; };
  adapterSource = adapter: lib.cleanSourceWith {
    src = repoRoot;
    name = "paykit-${adapter}-source";
    filter = path: type:
      let
        relative = lib.removePrefix "${toString repoRoot}/" (toString path);
        selected = toString path == toString repoRoot
          || relative == "go"
          || lib.hasPrefix "go/" relative
          || relative == "harness"
          || relative == "harness/${adapter}"
          || lib.hasPrefix "harness/${adapter}/" relative;
      in
      selected
      && lib.cleanSourceFilter path type
      && !(builtins.elem (builtins.baseNameOf path) [ "vendor" "paykit-server" ]);
  };
  mkAdapter = adapter: buildGoModule {
    pname = "paykit-${adapter}";
    version = "0.1.0";
    src = adapterSource adapter;
    modRoot = "harness/${adapter}";
    subPackages = [ "." ];

    # Cache downloaded modules, preserving the SDK's local replace path. Copying
    # the SDK into a vendor tree would require a new fixed hash on every SDK edit.
    proxyVendor = true;
    vendorHash = hashes.${adapter};
    env.GOTOOLCHAIN = "local";
    env.GOWORK = "off";
    doCheck = false;
    postInstall = ''
      mv "$out/bin/${adapter}" "$out/bin/paykit-${adapter}"
    '';
    meta = {
      description = "Cached ${adapter} adapter for the experimental CI";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
      mainProgram = "paykit-${adapter}";
    };
  };
in
{
  go-client = mkAdapter "go-client";
  go-server = mkAdapter "go-server";
}
