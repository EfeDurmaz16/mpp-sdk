{
  description = "Experimental PayKit polyglot CI alongside the native workflows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/b6c8664de9b6cc07fe5666a29f91884ba81197c4";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-darwin" ];
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
          languages = builtins.removeAttrs toolchains.tools
            ([ "common" ] ++ pkgs.lib.optional pkgs.stdenv.isLinux "swift");
        in builtins.mapAttrs (_: tools: pkgs.mkShell {
          packages = toolchains.tools.common ++ tools;
          GOTOOLCHAIN = "local";
          GOWORK = "off";
          UV_PYTHON_DOWNLOADS = "never";
        }) languages);

      lib.toolVersions = forAllSystems (system:
        let inherit (context system) toolchains;
        in builtins.mapAttrs (_: tool: tool.version) {
          inherit (toolchains) nodejs pnpm go rust cargo java gradle python ruby php lua;
        });
    };
}
