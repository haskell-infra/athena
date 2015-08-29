{ config, pkgs, ... }:

{
  ## ---------------------------------------------------------------------------
  ## Global, common configuration/system options

  imports =
    [ ../../../hardware-configuration.nix
      ../../../rackspace-configuration.nix
    ];

  ## -- Boot configuration
  boot.loader.grub.enable  = true;
  boot.loader.grub.version = 2;
  boot.cleanTmpDir         = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # -- Shell setup
  users.defaultUserShell = "/var/run/current-system/sw/bin/zsh";
  programs.zsh.enable = true;

  ## -- OpenSSH, NTP
  services.openssh.enable = true;
  services.ntp.enable = true;

  ## -- Nix options
  nix.package       = pkgs.nixUnstable;
  nix.readOnlyStore = true;
  nix.gc.automatic  = false;
  nix.useChroot     = true;
  nix.buildCores    = 0;
  nix.nrBuildUsers  = 32;
  nix.trustedBinaryCaches  = [ "https://cache.nixos.org" "https://hydra.nixos.org" ];
  nix.binaryCaches  = [ "https://cache.nixos.org" "https://hydra.nixos.org" ];
  nix.binaryCachePublicKeys = [ "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs=" ];
  nix.extraOptions  = ''
    auto-optimise-store = true
  '';

  ## -- I18n
  i18n.consoleFont   = "lat9w-16";
  i18n.consoleKeyMap = "us";
  i18n.defaultLocale = "en_US.UTF-8";

  ## -- Networking
  networking.extraHosts
    = "127.0.0.1 localhost ${config.networking.hostName}";
    # Required so Emacs isn't slow as molasses

  networking.wireless.enable = false;
  networking.firewall.enable = true;
  networking.firewall.rejectPackets = false;
  networking.firewall.allowPing = true;
  networking.firewall.allowedTCPPorts =
    [ 22
    ];
  networking.firewall.allowedUDPPorts =
    [
    ];
  networking.firewall.allowedUDPPortRanges =
    [ { from = 60000; to = 61000; } ]; # Mosh port ranges

  environment.systemPackages = with pkgs; [];
    [ binutils
      cacert
      checksec
      emacs24-nox
      file
      git
      htop
      iotop
      lsof
      mosh
      openssl
      psmisc
      linuxPackages.perf
      reptyr
      scrypt
      silver-searcher
      tmux
      unzip
      vim
      wget
      xz
      zsh
    ];

  ## -- Package/time configuration
  nixpkgs.config = import ../nixpkgs/config.nix;
  time.timeZone = "America/Chicago";

  ## -- Users
  users.extraUsers.a = {
    isNormalUser = true;
    home = "/home/a";
    description = "Austin Seipp";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys =
      [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKN53e1R17ha560eN3TJ/uV63vgppBVOGB2bZ5H7AnvVdrV6ZnrRU0LY9VBx0bF5q2+Hst8X9xOuTKLg38XFLkSWjI0Bxt4qYbwRr8RyafI8n0UUV/sLFPEkVw2Y2jUlMxGhPUtCXZbB8V2n8Zcn/QESnUKOzZHGh2VuQ1ydra58gCK6jDot51lNh4oT0WL3F+KY7cKGv5uyDLtaGxxiPYBRZvhBLjdPAYfkTa1NOAYoN3wPfFtH4xuCP2nTSbodAgQ/UsY/aNdNkK97//GZzT5h7cA4G+//b5tNaGCN0j7RJ6wSGFCut3QvKiYlsU0sAuwyYhizuo/+IoWV2LT2W6pHRe5Ivodyzm97bkWzI+UzGKLP5VKH55Pol4iIhnavhUP5j4IIr5Xplbvp+BdVVgfaSWpRH0t4ALyn1oDZZNUkzjwFbw/EPkdndJjChziEPO31koPBFcm/IB7DvXYjPrTY9S5nlF7QbA2A3118oem4V9A4FNi9gijFJspkHPFJ2CzFoYbCg9fCwPkeS/poS6ZgBL0p4sMoqxj+2OUdS6Vg8IO143YIUmA7FcFYafhhpTWSD44lja7a8RkDcukOA2YdcuMf5f10xbW3auZ3Gjatj1Jp0hTqIT78FaEBoZJnSmJSwi/hyMWV/vix+SCw3BPwjIJ/xQUccpNwh++E/Zdw== a@link"
      ];
  };
}
