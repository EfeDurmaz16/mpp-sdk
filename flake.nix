{
  description = "Experimental PayKit polyglot CI alongside the native workflows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b6c8664de9b6cc07fe5666a29f91884ba81197c4";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      lanes = builtins.fromJSON (builtins.readFile ./nix/ci-lanes.json);
      forAllSystems = nixpkgs.lib.genAttrs systems;
      context = system:
        let
          pkgs = import nixpkgs { inherit system; };
          toolchains = import ./nix/toolchains.nix { inherit pkgs; };
        in { inherit pkgs toolchains; };
    in {
      packages = forAllSystems (system:
        let c = context system;
        in (import ./nix/packages/rust.nix c)
          // (import ./nix/packages/go.nix c)
          // (import ./nix/packages/typescript.nix c)
          // c.pkgs.lib.optionalAttrs c.pkgs.stdenv.isLinux
            (import ./nix/packages/payment-channels.nix c));

      devShells = forAllSystems (system:
        let
          inherit (context system) pkgs toolchains;
          inherit (pkgs) lib;
          languages = builtins.removeAttrs toolchains.tools
            ([ "common" ] ++ pkgs.lib.optional pkgs.stdenv.isLinux "swift");
          supported = builtins.filter
            (lane: lane.language != "swift" || pkgs.stdenv.isDarwin) lanes;
          laneShell = lane:
            let
              envNames = [ "GOTOOLCHAIN" "GOWORK" ]
                ++ lib.optionals (lane.language == "kotlin") [ "JAVA_HOME" ]
                ++ lib.optionals (lane.language == "rust") [ "LLVM_COV" "LLVM_PROFDATA" ]
                ++ lib.optionals (lane.language == "lua") [
                  "LUA_INCDIR" "LIBSODIUM_INCDIR" "LIBSODIUM_LIBDIR"
                  "OPENSSL_INCDIR" "OPENSSL_LIBDIR"
                ]
                ++ lib.optionals (lane.kind == "browser") [
                  "NIX_BROWSER_INTERPRETER" "NIX_BROWSER_LIBRARY_PATH"
                ];
              environment = builtins.intersectAttrs
                (lib.genAttrs envNames (_: true)) toolchains.environment;
            in pkgs.mkShell (environment // {
              packages = lib.unique (toolchains.tools.common
                ++ toolchains.tools.typescript ++ toolchains.tools.${lane.language}
                ++ lib.optionals (lane.kind == "browser") toolchains.tools.browser);
              CI = "1";
              UV_PYTHON_DOWNLOADS = "never";
              SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
              shellHook = ''
                export PATH="$PWD/.nix-work/bin:$PATH"
              '';
            });
        in (builtins.mapAttrs (_: tools: pkgs.mkShell {
          packages = toolchains.tools.common ++ tools;
          GOTOOLCHAIN = "local";
          GOWORK = "off";
          UV_PYTHON_DOWNLOADS = "never";
        }) languages) // builtins.listToAttrs (map (lane: {
          name = "ci-${lane.id}";
          value = laneShell lane;
        }) supported));

      apps = forAllSystems (system:
        let
          inherit (context system) pkgs;
          supported = builtins.filter
            (lane: lane.language != "swift" || pkgs.stdenv.isDarwin) lanes;
        in builtins.listToAttrs (map (lane: {
          name = lane.id;
          value = {
            type = "app";
            program = "${pkgs.writeShellScriptBin "paykit-${lane.id}" ''
              set -euo pipefail
              cd "$(git rev-parse --show-toplevel)"
              exec nix develop --no-update-lock-file .#ci-${lane.id} \
                --command bash nix/scripts/run.sh ${lane.kind} ${lane.lane} "$@"
            ''}/bin/paykit-${lane.id}";
          };
        }) supported));

      lib.ciMatrix.include = lanes;

      lib.toolVersions = forAllSystems (system:
        let inherit (context system) toolchains;
        in builtins.mapAttrs (_: tool: tool.version) {
          inherit (toolchains) nodejs pnpm go rust cargo java gradle python ruby php lua;
        });
    };
}
