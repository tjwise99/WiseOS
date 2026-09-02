{
  description = "WiseOS — NixOS and Home Manager configuration for the laptop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # claude-code ships several times a week; the nixos-26.05 branch backports
    # it rarely and is stuck far behind. This input exists solely to float that
    # one package forward (see claudeOverlay below) — nothing else follows it,
    # so the eval-critical set stays wholly on 26.05. Tracks the -small channel
    # rather than full unstable: it is Hydra-built (so claude-code and its deps
    # are in the binary cache) but advances on a smaller gate, so it carries a
    # newer claude-code than nixpkgs-unstable does.
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
        ];

      # Replaces just claude-code with the unstable build, keyed off whichever
      # package set is being extended so it works for both the standalone pkgs
      # below and the NixOS host's own set. The unstable import carries the same
      # unfree predicate so its claude-code evaluates. It shares nothing else
      # with the surrounding set — claude-code is a fetchurl of a prebuilt
      # binary — so this does not reintroduce the cross-release eval risk the
      # follows above are avoiding.
      claudeOverlay = _final: prev: {
        inherit
          (import nixpkgs-unstable {
            inherit (prev.stdenv.hostPlatform) system;
            config = { inherit allowUnfreePredicate; };
          })
          claude-code
          ;
      };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ claudeOverlay ];
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
            nixpkgs.overlays = [ claudeOverlay ];
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
