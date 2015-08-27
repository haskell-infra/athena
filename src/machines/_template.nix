{ config, pkgs, ... }:

{
  imports =
    [ ./common.nix
    ];

  networking.hostName = "HOSTNAME";

  environment.systemPackages = with pkgs;
     [ wget
     ];
}
