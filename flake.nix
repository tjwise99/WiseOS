{
  description = "WiseOS — NixOS and Home Manager configuration for the laptop";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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

  outputs = { nixpkgs, home-manager, sops-nix, ... }:
    let
      system = "x86_64-linux";
      # One list, reaching both outputs. They take it by different routes:
      # nixosSystem builds its own pkgs from the nixpkgs.* options, so it is
      # handed this as a module below; homeManagerConfiguration builds none and
      # requires a package set, so one is instantiated here.
      allowUnfreePredicate = pkg:
        builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];

      pkgs = import nixpkgs {
        inherit system;
        config = { inherit allowUnfreePredicate; };
      };

      # Home Manager against a distro Nix did not build — Manjaro here, Ubuntu
      # under WSL. targets.genericLinux fixes up XDG_DATA_DIRS and the session
      # variables so store packages reach a system that knows nothing about
      # them; it is meaningless on NixOS, hence here and not in the shared file.
      #
      # The username is the only thing the two hosts can disagree about, so it
      # is the argument rather than a second copy of the module list.
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
        # The Manjaro laptop:
        #     home-manager switch --flake .#wise
        wise = genericLinuxHome "wise";

        # The Ubuntu WSL box, on the same home/wise.nix:
        #     home-manager switch --flake .#wsl
        wsl = genericLinuxHome "tjwise";
      };

      # The future bare-metal machine. Bootable from Manjaro without installing
      # anything, which is what makes this config testable before it is applied:
      #     nixos-rebuild build-vm --flake .#wise-laptop
      #
      # No `system` argument: nixpkgs.hostPlatform in hardware-configuration.nix
      # is what sets it, and passing both is an eval conflict.
      nixosConfigurations.wise-laptop = nixpkgs.lib.nixosSystem {
        modules = [
          ./hosts/wise-laptop
          { nixpkgs.config.allowUnfreePredicate = allowUnfreePredicate; }
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
