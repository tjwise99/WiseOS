# Installing WiseOS on metal

This is the one-way step the rest of the repo was built to make safe: everything until now runs from
Manjaro without touching the disk, and this replaces Manjaro with the NixOS defined in
`nixosConfigurations.wise-laptop`. Read it through once before starting — two of the steps (saving
the age key, setting the real password hash) happen *on the current system*, and are painful to
recover from if the disk is already wiped.

The end state: the laptop boots NixOS, the `wise` account logs in with a password that was never
committed in plaintext or copied into `/nix/store`, and `dotfiles-provision` has laid down the
desktop on first boot.

## Before you wipe anything

Two things live only on the current machine and are gone the moment the disk is reformatted.

**The age private key.** `~/.config/sops/age/keys.txt` is what decrypts your login password on the
new system. Copy it somewhere off the laptop — the installer USB, or a second stick:

```sh
cp ~/.config/sops/age/keys.txt /run/media/wise/USB/keys.txt   # adjust the mount path
```

Losing it is not fatal — you can generate a new key, re-encrypt `secrets.yaml` against it
(`sops updatekeys`, see [`README.md` → Secrets](../README.md#secrets)), and commit that — but doing
it after the wipe means doing it from the installer with no editor you are used to. Save the key.

**Your real login password.** The committed `secrets.yaml` holds a placeholder — the hash of
`changeme` — so the config evaluates and the VM builds. Replace it with the hash of a password you
choose, *from Manjaro*, where `sops` and your key are already set up:

```sh
# Type your password; copy the $y$... line it prints. -m yescrypt matches NixOS's default.
nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt

# Open the encrypted file in $EDITOR, replace the wise_password_hash value, save.
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  nix shell nixpkgs#sops -c sops hosts/wise-laptop/secrets.yaml
```

The value you paste is a hash, not the password, and the whole file is encrypted at rest — so commit
and push it. The installer clones this repo, and it needs to clone the version with *your* hash:

```sh
git add hosts/wise-laptop/secrets.yaml && git commit -m "secrets: set real wise password" && git push
```

**Anything else you care about.** The repo and `~/dotfiles` are on GitHub; `~/dotfiles/local/` is
deliberately unsynced, so SSH keys, browser profiles and anything under it exist nowhere else. Back
up what you need.

## Disk layout — the one real decision

The config names two filesystems by label (`hardware-configuration.nix`): an ESP labelled `BOOT` and
a root labelled `nixos`. How you carve the disk to produce them is the choice.

**Wipe Manjaro (recommended).** The whole disk becomes NixOS. Simplest, and the only option that
gives the 512 M ESP entirely to NixOS rather than sharing it. A fresh GPT with two partitions:

| Partition | Size | Type | Filesystem | Label |
| --- | --- | --- | --- | --- |
| 1 | 512 MiB | EFI System | FAT32 | `BOOT` |
| 2 | rest | Linux filesystem | ext4 | `nixos` |

**Dual-boot.** Shrink the existing Manjaro root from a live USB *first* (with `gparted` or
`parted`), then add the ext4 `nixos` partition in the freed space and reuse Manjaro's existing ESP as
`BOOT`. The catch worth knowing before you commit: a 512 M ESP shared between two distros' kernels is
tight — NixOS keeps a kernel and initrd per generation there, which is why
`boot.loader.systemd-boot.configurationLimit` is already pinned to 10. If you dual-boot, watch that
the shared ESP does not fill, and reuse the existing ESP label rather than reformatting it (that
would strip Manjaro's boot entries).

### Retaining a separate /home

If `/home` is its own partition — which this laptop has — keep it and reinstall only the system. The
rule is one line: **format the root partition, never the home partition.** Everything under `/home`
survives, including `~/dotfiles`, which makes first-boot provisioning a near no-op — it finds the
clone already there and skips it.

Three things to get right:

- **Never `mkfs` the home partition.** In step 1 below, format only root (`nixos`) and, if wiping the
  rest, the ESP (`BOOT`). Leave the home partition alone.
- **Mount it before `nixos-generate-config`.** Mount the existing home partition at `/mnt/home`
  (step 2), and the generator writes its `fileSystems."/home"` entry for you — no hand-editing beyond
  reducing its UUID to a label, as for the others. Give it a label first if it has none:
  `e2label /dev/nvme0n1pN home` renames the label and touches no data.
- **Match the owner.** The config pins `wise` to `uid = 1000` — almost certainly what a Manjaro first
  user is; confirm with `ls -ln /mnt/home` (read the numeric owner column). If it is 1000 the files
  stay owned correctly. If the primary *group* differs — Manjaro's per-user group versus NixOS's
  shared `users` (gid 100) — fix it once after install:
  `nixos-enter --root /mnt -c 'chown -R wise:users /home/wise'`.

Back up `/home` anyway. A slip in step 1 — formatting the wrong partition — erases it, and that is the
one mistake this runbook cannot undo.

The steps below assume the **wipe** path on an NVMe disk. Run `lsblk` first and substitute your
actual device — `/dev/nvme0n1` here, `/dev/sda` on a SATA disk. **This erases the disk.**

## Install

Boot a recent NixOS installer USB (the minimal ISO is enough) and bring up the network — `iwctl` for
wifi, or plug in ethernet.

**1. Partition and format**, producing the two labels the config expects:

```sh
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 513MiB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart primary 513MiB 100%

mkfs.fat -F32 -n BOOT /dev/nvme0n1p1
mkfs.ext4 -L nixos    /dev/nvme0n1p2
```

**2. Mount** by label, exactly as the config will:

```sh
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=0077 /dev/disk/by-label/BOOT /mnt/boot

# Retaining a separate /home? Mount it too, BEFORE nixos-generate-config, so the
# generator picks it up. Do not format it.
# mkdir -p /mnt/home && mount /dev/disk/by-label/home /mnt/home
```

**3. Generate the hardware config**, which is the only file this install writes that the repo does
not already carry:

```sh
nixos-generate-config --root /mnt
```

This writes `/mnt/etc/nixos/hardware-configuration.nix` describing *this* machine's disks and kernel
modules. The repo ships a placeholder for that file; you are about to replace it. Two edits to the
generated file before it goes in:

- **Reduce `/dev/disk/by-uuid/…` to `by-label`.** `nixos-generate-config` names filesystems by UUID.
  The config, and `just check-privacy`, both want labels — `nixos` and `BOOT`, the ones you formatted
  with. Rewrite the two `fileSystems` device lines to `/dev/disk/by-label/nixos` and
  `/dev/disk/by-label/BOOT`. A committed UUID is what `check-privacy` rejects, and it fingerprints
  the machine.
- **Drop `configuration.nix`.** You do not need the generated `configuration.nix` at all — the flake
  is the configuration. Only the hardware file carries over.

**4. Get the flake and your hardware file onto the target:**

```sh
nix-shell -p git --run '
  git clone https://github.com/tjwise99/WiseOS /mnt/etc/nixos/WiseOS'
cp /mnt/etc/nixos/hardware-configuration.nix \
   /mnt/etc/nixos/WiseOS/hosts/wise-laptop/hardware-configuration.nix
# now apply the two edits above to that copy
```

**5. Place the age key** so the very first activation can decrypt your password. The keyFile path the
config reads is `/var/lib/sops-nix/key.txt`; under the installer that is `/mnt/var/lib/…`:

```sh
mkdir -p /mnt/var/lib/sops-nix
cp /run/media/wise/USB/keys.txt /mnt/var/lib/sops-nix/key.txt   # the key you saved earlier
chmod 600 /mnt/var/lib/sops-nix/key.txt
```

**Prove the key decrypts before you rely on it.** The password hash is consumed exactly once — when
`nixos-install` creates the account — and a wrong or mistyped key path does not fail the install; it
silently creates a *locked* account you only discover at the login screen. Catch it now, while it is
still a one-line fix:

```sh
SOPS_AGE_KEY_FILE=/mnt/var/lib/sops-nix/key.txt \
  nix shell nixpkgs#sops -c sops -d /mnt/etc/nixos/WiseOS/hosts/wise-laptop/secrets.yaml
```

That must print `wise_password_hash: $y$…`. If it errors instead, the key is wrong — stop and fix it
before installing.

**6. Install:**

```sh
nixos-install --flake /mnt/etc/nixos/WiseOS#wise-laptop
```

`nixos-install` prompts for a **root** password at the end — that is the `root` account, separate
from `wise`. The `wise` password is not prompted: it is decrypted from `secrets.yaml` during this
install's activation, using the key you just placed.

**Confirm the account is not locked before you reboot.** `nixos-install` exits 0 even if the password
step failed, so check the shadow entry from inside the new system while you can still fix it from the
installer:

```sh
nixos-enter --root /mnt -c 'getent shadow wise' | cut -d: -f2
```

That field must be a `$y$…` hash. If it is `!`, `*`, or empty, the password did not land — the most
likely cause is the key, so re-check the decrypt test above, then
`nixos-enter --root /mnt -c 'passwd wise'` to set one by hand before rebooting. A later
`nixos-rebuild switch` will **not** repair it: with `mutableUsers = true` the hash is written only at
account creation, so once `wise` exists, only `passwd` changes it.

## First boot

Reboot and remove the USB. Log in as `wise` with the password you hashed into `secrets.yaml`. Then
prove the secret path did what it claims — decrypted, and never in the store:

```sh
sudo test -f /run/secrets-for-users/wise_password_hash && echo "decrypted at boot: yes"
grep -rl "$(sudo cat /run/secrets-for-users/wise_password_hash)" /nix/store 2>/dev/null \
  && echo "LEAKED INTO STORE" || echo "not in store: good"
```

`dotfiles-provision` runs on first boot — it clones `dotfiles` over HTTPS and runs `./install` once,
then restarts i3 so the bar and theme come up. It clones over HTTPS because a fresh machine has no
SSH key, which means `tools/sync.sh` cannot push until you switch the remote:

```sh
git -C ~/dotfiles remote set-url origin git@github.com:tjwise99/dotfiles.git
```

Until you do, the shell reports a sync failure at every prompt — the chosen trade, not a bug, and it
clears the moment the remote is SSH and a key exists.

## What is only testable here

The VM has no radio and no real GPU, so wifi, backlight, suspend and Intel graphics get their first
real exercise now. Do it from the installer USB if you can still boot it — iterating on a graphics or
suspend problem is far cheaper there than from a half-installed disk.
