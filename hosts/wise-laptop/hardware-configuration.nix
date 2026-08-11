# PLACEHOLDER. Replaced wholesale by `nixos-generate-config` during the metal
# install, which is the only thing that can read this machine's real disks.
#
# It exists so the config evaluates and so `nixos-rebuild build-vm` works from
# Manjaro: the QEMU module overrides fileSystems with mkVMOverride, so the
# devices named here are ignored in a VM and only the platform and kernel
# modules carry through.
{ config, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # Set here rather than as a `system` argument to nixosSystem — one or the
  # other, never both.
  nixpkgs.hostPlatform = "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
