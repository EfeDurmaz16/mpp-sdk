{
  description = "Experimental PayKit polyglot CI alongside the native workflows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b6c8664de9b6cc07fe5666a29f91884ba81197c4";

  inputs.crane.url = "github:ipetkov/crane/47b6b27ed9a3a9181415e4367d0c30ab2a0e0250";

  outputs = { self, nixpkgs, crane }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      lanes = builtins.fromJSON (builtins.readFile ./nix/ci-lanes.json);
      forAllSystems = nixpkgs.lib.genAttrs systems;
      context = system:
        let
          pkgs = import nixpkgs { inherit system; };
          toolchains = import ./nix/toolchains.nix { inherit pkgs; };
        in { inherit pkgs toolchains; craneLib = crane.mkLib pkgs; };
      laneEnvironment = c: lane:
        let
          inherit (c.pkgs) lib;
          names = [ "GOTOOLCHAIN" "GOWORK" ]
            ++ lib.optionals (lane.language == "kotlin") [ "JAVA_HOME" ]
            ++ lib.optionals (lane.language == "rust" && lane.kind == "unit") [ "LLVM_COV" "LLVM_PROFDATA" ]
            ++ lib.optionals (lane.language == "swift" && lane.kind != "demo") [ "DYLD_LIBRARY_PATH" ]
            ++ lib.optionals (lane.language == "lua") [
              "LUA_INCDIR" "LIBSODIUM_INCDIR" "LIBSODIUM_LIBDIR"
              "OPENSSL_INCDIR" "OPENSSL_LIBDIR"
            ]
            ++ lib.optionals (lane.kind == "browser") [
              "NIX_BROWSER_INTERPRETER" "NIX_BROWSER_LIBRARY_PATH"
            ];
        in builtins.intersectAttrs (lib.genAttrs names (_: true)) c.toolchains.environment;
      laneTools = c: lane:
        let
          inherit (c.pkgs) lib;
          tools = c.toolchains.tools;
          languageTools = if (lane.language == "swift" && lane.kind == "interop")
            || (lane.language == "rust" && lane.kind == "browser") then [ ]
            else if lane.language == "go" && builtins.elem lane.kind [ "interop" "browser" ]
            then [ c.toolchains.go ] else tools.${lane.language};
          needsNode = lane.language == "typescript"
            || builtins.elem lane.kind [ "interop" "browser" ];
        in lib.unique (tools.common ++ languageTools
          ++ lib.optionals needsNode tools.typescript
          ++ lib.optionals (lane.kind == "browser") tools.browser);
    in {
      packages = forAllSystems (system:
        let
          c = context system;
          ts = import ./nix/packages/typescript.nix { inherit (c) pkgs toolchains; };
        in ts
          // (import ./nix/packages/rust.nix (c // { htmlAssets = ts.html-assets; }))
          // (import ./nix/packages/go.nix c)
          // c.pkgs.lib.optionalAttrs c.pkgs.stdenv.isDarwin
            (import ./nix/packages/swift.nix c)
          // c.pkgs.lib.optionalAttrs c.pkgs.stdenv.isLinux
            (import ./nix/packages/payment-channels.nix { inherit (c) pkgs toolchains; }));

      devShells = forAllSystems (system:
        let
          inherit (context system) pkgs toolchains;
          inherit (pkgs) lib;
          languages = builtins.removeAttrs toolchains.tools
            ([ "common" ] ++ pkgs.lib.optional pkgs.stdenv.isLinux "swift");
          supported = builtins.filter
            (lane: lane.language != "swift" || pkgs.stdenv.isDarwin) lanes;
          laneShell = lane: pkgs.mkShell ((laneEnvironment (context system) lane) // {
            packages = laneTools (context system) lane;
            CI = "1";
            UV_PYTHON_DOWNLOADS = "never";
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          });
        in (builtins.mapAttrs (language: tools: pkgs.mkShell ({
          packages = toolchains.tools.common ++ tools;
          GOTOOLCHAIN = "local";
          GOWORK = "off";
          UV_PYTHON_DOWNLOADS = "never";
        } // lib.optionalAttrs (language == "swift") {
          inherit (toolchains.environment) DYLD_LIBRARY_PATH;
        })) languages) // builtins.listToAttrs (map (lane: {
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
              ${if (lane.language == "swift" && lane.kind == "interop")
                || (lane.language == "rust" && lane.kind == "browser")
                || lane.language == "typescript" then ''
              export PATH="${pkgs.lib.makeBinPath (laneTools (context system) lane)}:$PWD/.nix-work/bin:$PATH"
              export CI=1 UV_PYTHON_DOWNLOADS=never
              export SSL_CERT_FILE=${pkgs.lib.escapeShellArg "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"}
              ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList
                (name: value: "export ${name}=${pkgs.lib.escapeShellArg value}")
                (laneEnvironment (context system) lane))}
              exec bash nix/scripts/run.sh ${lane.kind} ${lane.lane} "$@"
              '' else ''
                exec nix develop --no-update-lock-file .#ci-${lane.id} \
                  --command bash nix/scripts/run.sh ${lane.kind} ${lane.lane} "$@"
              ''}
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
