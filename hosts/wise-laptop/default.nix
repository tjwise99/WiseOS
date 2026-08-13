{ config, pkgs, lib, ... }:

let
  # theme.sh's gtk source reads the active GTK theme through gi, which needs the
  # bindings and the introspection typelibs for everything it imports. Wrapped
  # rather than exported into the session: the typelibs live in each library's
  # `out` output, and environment.systemPackages installs the default one —
  # which for pango and glib is `bin` and carries none. A GI_TYPELIB_PATH
  # pointing at the system profile therefore finds Gtk and not Pango, and
  # from_gtk fails on an override assertion rather than on anything legible.
  gtkPython = pkgs.symlinkJoin {
    name = "python3-gtk";
    paths = [ (pkgs.python3.withPackages (ps: [ ps.pygobject3 ])) ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/python3 --prefix GI_TYPELIB_PATH : \
        "${lib.makeSearchPathOutput "out" "lib/girepository-1.0" [
          pkgs.gtk3
          pkgs.glib
          pkgs.pango
          pkgs.at-spi2-core
          pkgs.gdk-pixbuf
          pkgs.harfbuzz
          pkgs.gobject-introspection
        ]}"
    '';
  };
in

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
  programs.nix-ld.enable = true;

  users.users.wise = {
    isNormalUser = true;
    description = "Wise";
    extraGroups = [ "wheel" "video" "audio" ];
    shell = pkgs.zsh;

    # Consumed once, at first activation, and only if the account has no
    # password yet. Fine for a VM; set a real one with passwd on first login,
    # before this config ever reaches metal.
    initialPassword = "changeme";
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono   # polybar's glyphs and alacritty both name it
    dejavu_fonts
    noto-fonts
    noto-fonts-color-emoji
  ];

  environment.systemPackages = with pkgs; [
    git
    vim
    
    # Required by dotfiles' ./install. dotbot runs shell: steps with $SHELL,
    # and NixOS's /etc/zshenv sources /etc/set-environment, which assigns PATH
    # rather than extending it — so the unit's own `path` is discarded as soon
    # as a shell step runs. Only what is declared here survives that.
    gtkPython
    gnumake
    gcc
    gnutar
    gzip
    unzip
    curl

    # Desktop — derived from the exec targets in dotfiles/i3/config
    alacritty
    (polybar.override {
      i3Support = true;
      pulseSupport = true;
    })
    picom
    rofi
    dunst
    feh
    xclip
    maim
    pavucontrol
    brightnessctl
    playerctl
    xss-lock
    pywal
    batsignal
    impala
    brave
    opencloud-desktop
    xrdb
    libnotify
    betterlockscreen
    pulseaudio
  ];

  # First-boot provisioning: clone the dotfiles repo and run its installer once.
  #
  # Not a home.activation step — that runs inside home-manager-wise.service,
  # which has TimeoutStartSec=5m, and asdf compiles rust and golang.
  systemd.services.dotfiles-provision = {
    description = "Clone dotfiles and run its installer, once";
    wantedBy = [ "multi-user.target" ];
    after = [ "nix-daemon.socket" ];

    path = with pkgs; [ bash python3 git openssh curl unzip gnutar gzip gnumake gcc coreutils ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "wise";
      TimeoutStartSec = "infinity";
    };

    script = ''
      set -uo pipefail
      cd "$HOME"

      # Deliberately not ordered on network-online.target: iwd owns wlan0
      # outside networkd and the wired link is RequiredForOnline=no, so nothing
      # is left for systemd-networkd-wait-online to wait for and it times out
      # instead of returning — the reason system/apply.sh disables that unit.
      # Retrying is what actually works here.
      if [ ! -d dotfiles/.git ]; then
        for attempt in 1 2 3 4 5 6; do
          git clone https://github.com/tjwise99/dotfiles.git dotfiles && break
          echo "clone failed (attempt $attempt) — retrying in 15s"
          sleep 15
        done
      fi
      [ -d dotfiles/.git ] || { echo "no network — run ./install by hand"; exit 1; }

      if [ ! -e "$HOME/.dotfiles-provisioned" ]; then
        cd dotfiles && ./install && touch "$HOME/.dotfiles-provisioned"
      fi
    '';
  };

  # VM-only. Applied when building system.build.vm, ignored on real hardware,
  # so it can live here permanently rather than being a branch to remember.
  virtualisation.vmVariant = {
    # The default is 1 core and 1024M. Compiling the Go and Rust toolchains in
    # that is slow at best, and low memory is a good candidate for the failure
    # you just hit — Go's runtime reports allocation and thread-creation
    # failures in ways that read like concurrency bugs.
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.diskSize = 20480;
    virtualisation.qemu.options = [ "-vga qxl" ];

    # SSH from the host, so the VM is usable from a real terminal: copy/paste,
    # scrollback, and reading a journal without retyping it.
    services.openssh.enable = true;
    virtualisation.forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];

    # The laptop's own key, so the forwarded port is reachable without a tty to
    # type initialPassword into. That is what makes the VM scriptable.
    users.users.wise.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIApZ86+DW+jVdB2ybqMxM3GwfacbqO07r8Q17z0w9JSc tjwise99@wise-laptop"
    ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # The release whose defaults this config was written against. Not a version
  # to bump for newness — changing it opts into changed stateful defaults.
  system.stateVersion = "26.05";
}
