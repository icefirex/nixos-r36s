# Minimal NixOS configuration for R36S handheld
{ pkgs, lib, ... }:
{
  imports = [
    ./r36s-hardware.nix
    ./sd-image.nix
  ];

  system.stateVersion = "25.11";

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "r36s";
  networking.dhcpcd.enable = false;
  networking.firewall.enable = false;

  # ZFS is broken on latest kernel and not needed
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # No man pages, NixOS manual, or info pages needed on handheld
  documentation.enable = false;

  # Disable kernel audit subsystem
  security.audit.enable = false;

  # No DNS or real networking — nscd is unnecessary
  services.nscd.enable = false;
  system.nssModules = lib.mkForce [];

  # Only spawn getty on tty1, auto-login as root
  services.getty.autologinUser = "root";

  # Cap journal storage
  services.journald.extraConfig = "SystemMaxUse=16M";

  # SSH for headless debugging during bringup
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings.PermitRootLogin = "yes";
  };

  users.users.root = {
    initialPassword = "nixos";
    # openssh.authorizedKeys.keys = [
    #   "your-ssh-public-key-here"
    # ];
  };

  # zram swap - critical with only 1 GB RAM
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  environment.systemPackages = with pkgs; [
    vim
    htop
    evtest       # test joypad/input events
    usbutils
  ];
}
