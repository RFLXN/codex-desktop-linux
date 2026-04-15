{
  description = "Codex Desktop for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "codex-desktop" ];
        };
        package = pkgs.callPackage ./pkg.nix { };
      in
      {
        packages = {
          default = package;
          installer = package;
        };

        apps.default = {
          type = "app";
          program = "${package}/bin/codex-desktop";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.python3
            pkgs.p7zip
            pkgs.curl
            pkgs.unzip
            pkgs.gnumake
            pkgs.gcc
          ];
        };
      }
    );
}
