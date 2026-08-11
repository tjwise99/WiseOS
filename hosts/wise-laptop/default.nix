{ pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The ESP on this machine is 512M. NixOS keeps a kernel and initrd per
  # generation there, so an unbounded list fills it and then boot breaks at the
  # worst possible moment — during an update.
  boot.loader.systemd-boot.configurationLimit = 10;

  networking.hostName = "wise-laptop";

  # Network stack carried over from dotfiles/system/, where the reasoning was
  # worked out against this hardware. iwd owns wlan0 outright, including DHCP,
  # so no second daemon holds the radio.
  networking.wireless.iwd = {
    enable = true;
    settings = {
      General.EnableNetworkConfiguration = true;
      Network.NameResolvingService = "systemd";
    };
  };

  # useNetworkd rather than a bare systemd.network.enable: the latter leaves the
  # scripting path and its dhcpcd in place, so both would manage the same links.
  # DHCP is declared per-network below, never globally.
  networking.useNetworkd = true;
  networking.useDHCP = false;
  services.resolved.enable = true;

  systemd.network.networks."20-wired" = {
    # en* rather than a PCI-slot name: covers the predictable wired names
    # without reaching wlan0, docker0 or a veth pair, and survives a NIC swap.
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";

    # Wired wins while a cable is in; wifi takes back over on unplug, because
    # networkd withdraws this route with the carrier. Has to beat iwd's metric,
    # which is RoutePriorityOffset plus the interface index — 300 by default.
    dhcpV4Config.RouteMetric = 100;

    # This port is usually empty, so it must never gate the machine being online.
    linkConfig.RequiredForOnline = "no";
  };

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  services.xserver.enable = true;
  services.xserver.windowManager.i3.enable = true;
  services.xserver.xkb.layout = "us";

  programs.zsh.enable = true;

  users.users.wise = {
    isNormalUser = true;
    description = "Wise";
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;

    # Consumed once, at first activation, and only if the account has no
    # password yet. Fine for a VM; set a real one with passwd on first login,
    # before this config ever reaches metal.
    initialPassword = "changeme";
  };

  environment.systemPackages = with pkgs; [
    git
    vim
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # The release whose defaults this config was written against. Not a version
  # to bump for newness — changing it opts into changed stateful defaults.
  system.stateVersion = "26.05";
}
