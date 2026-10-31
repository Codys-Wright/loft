{
  description = "Loft — a creative-work desktop: niri + a Quickshell shell, Liquid Glass, runtime-themeable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      imports = [
        ./nix/packages.nix
        ./nix/apps.nix
        ./nix/dev-shell.nix
        ./nix/checks.nix
        ./nix/modules/home.nix
        ./nix/modules/nixos.nix
        ./nix/modules/fans.nix
        ./nix/lock.nix
      ];
    };
}
