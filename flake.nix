{
  description = "WiseOS — NixOS and Home Manager configuration for the laptop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # claude-code ships several times a week; the nixos-26.05 branch backports
    # it rarely and is stuck far behind. This input exists solely to float a few
    # named packages forward (see unstableOverlay below) — nothing else follows
    # it, so the eval-critical set stays wholly on 26.05. Tracks the -small
    # channel rather than full unstable: it is Hydra-built (so its packages and
    # deps are in the binary cache) but advances on a smaller gate, so it
    # carries newer builds than nixpkgs-unstable does.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    # Pinned to the matching release branch, and made to follow nixpkgs so both
    # outputs below evaluate against one package set. A Home Manager release
    # tracks a nixpkgs release; crossing them is the usual source of eval errors.
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets encrypted at rest, decrypted into /run/secrets at activation —
    # never into the world-readable store. Follows this flake's nixpkgs for the
    # same one-package-set reason as home-manager above. Only the NixOS output
    # consumes it; the Home Manager outputs carry no secrets.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, nixpkgs-unstable, home-manager, sops-nix, ... }:
    let
      system = "x86_64-linux";
      # One list, reaching both outputs. They take it by different routes:
      # nixosSystem builds its own pkgs from the nixpkgs.* options, so it is
      # handed this as a module below; homeManagerConfiguration builds none and
      # requires a package set, so one is instantiated here.
      allowUnfreePredicate = pkg:
        builtins.elem (nixpkgs.lib.getName pkg) [ 
          "claude-code" 
          "discord"
          "discord-unwrapped"
          "vscode"
          "code"               # vscode.fhs — the FHS wrapper is named after its binary
        ];

      # Replaces just the named packages with their unstable builds, keyed off
      # whichever package set is being extended so it works for both the
      # standalone pkgs below and the NixOS host's own set. The unstable import
      # carries the same unfree predicate so the unfree ones evaluate. Each is a
      # leaf application built against unstable's own libraries; anything in
      # the 26.05 set that takes one as an input (vscode-with-extensions, say)
      # gets the unstable build, and no 26.05 system component does.
      #
      # brave: nixpkgs dropped it 2026-11-03 for lacking a committer maintainer
      # (PR #582838 brave, brave-origin: drop) and re-added it 2026-11-07, which
      # unstable-small carries before the nixos-26.05 channel does. Drop this
      # once nixos-26.05 evaluates brave.
      #
      # vscode: 26.05 jumped 1.119 -> 1.144 without the build-script changes
      # those releases needed, so its 1.144 fails to build (#584492 vscode
      # 1.144.0 build failure) and, patched past that, cannot verify extension
      # signatures (#584184 vsce-sign EACCES). Unstable carries the fixed
      # script. Drop this once #584492 is closed on release-26.05.
      #
      # discord: the packaged desktop core pins an OpenH264 build; the
      # server-delivered client downloads its own and deletes the rest. When
      # they disagree, H.264 streams show no video (error 2012). Drop this once
      # nixos-26.05's discord loads the build the client downloads.
      unstableOverlay = _final: prev: {
        inherit
          (import nixpkgs-unstable {
            inherit (prev.stdenv.hostPlatform) system;
            config = { inherit allowUnfreePredicate; };
          })
          brave
          claude-code
          discord
          vscode
          ;
      };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ unstableOverlay ];
        config = { inherit allowUnfreePredicate; };
      };

      # Home Manager against a distro Nix did not build — the Ubuntu WSL box.
      # targets.genericLinux fixes up XDG_DATA_DIRS and the session variables so
      # store packages reach a system that knows nothing about them; it is
      # meaningless on NixOS, hence here and not in the shared file. Username is
      # the argument because the WSL account differs from the module's default.
      genericLinuxHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home/wise.nix
          {
            targets.genericLinux.enable = true;
            home.username = username;
            home.homeDirectory = "/home/${username}";
          }
        ];
      };
    in
    {
      homeConfigurations = {
        # The Ubuntu WSL box, on the same home/wise.nix:
        #     home-manager switch --flake .#wsl
        wsl = genericLinuxHome "tjwise";
      };

      # The bare-metal laptop — the live system this repo configures. Apply with
      # `sudo nixos-rebuild switch --flake .#wise-laptop`; build-vm still boots
      # the full config in QEMU to test a change before it reaches the metal:
      #     nixos-rebuild build-vm --flake .#wise-laptop
      #
      # No `system` argument: nixpkgs.hostPlatform in hardware-configuration.nix
      # is what sets it, and passing both is an eval conflict.
      nixosConfigurations.wise-laptop = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/wise-laptop
          {
            nixpkgs.config.allowUnfreePredicate = allowUnfreePredicate;
            nixpkgs.overlays = [ unstableOverlay ];
          }
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.wise = import ./home/wise.nix;
          }
        ];
      };
    };
}
