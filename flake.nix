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
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
    in
    {
      # Runs on the Manjaro install today:
      #     home-manager switch --flake .#wise
      homeConfigurations.wise = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [ ./home/wise.nix ];
      };

      # The future bare-metal machine. Bootable from Manjaro without installing
      # anything, which is what makes this config testable before it is applied:
      #     nixos-rebuild build-vm --flake .#wise-laptop
      #
      # No `system` argument: nixpkgs.hostPlatform in hardware-configuration.nix
      # is what sets it, and passing both is an eval conflict.
      nixosConfigurations.wise-laptop = nixpkgs.lib.nixosSystem {
        modules = [ ./hosts/wise-laptop ];
      };
    };
}
