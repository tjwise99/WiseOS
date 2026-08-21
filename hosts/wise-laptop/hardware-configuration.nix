# This machine's real hardware, captured by `nixos-generate-config` at install
# and kept by-label rather than the by-uuid it emits: the partitions are
# labelled (nixos, BOOT, home, swap), a committed UUID fingerprints the disk and
# `check-privacy` rejects it, and a label survives a reformat that changes the
# UUID.
#
# `nixos-rebuild build-vm` overrides fileSystems and swapDevices with
# mkVMOverride, so the devices named here are ignored in a VM and only the
# platform and kernel modules carry through.
{ config, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "sd_mod" ];
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

  fileSystems."/home" = {
    device = "/dev/disk/by-label/home";
    fsType = "ext4";
  };

  swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];

  # Set here rather than as a `system` argument to nixosSystem — one or the
  # other, never both.
  nixpkgs.hostPlatform = "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
