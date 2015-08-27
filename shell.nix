{ pkgs ? import <nixpkgs> {} }: (import ./release.nix {}).shell
