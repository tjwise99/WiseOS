# Installing WiseOS on metal

This is the one-way step the rest of the repo was built to make safe: everything until now runs from
Manjaro without touching the disk, and this replaces Manjaro with the NixOS defined in
`nixosConfigurations.wise-laptop`. Read it through once before starting — the *Before you wipe* steps
happen *on the current system* and are painful to recover from once the disk has been touched.

The end state: the laptop boots NixOS, the `wise` account logs in with a password that was never
committed in plaintext or copied into `/nix/store`, and `dotfiles-provision` has laid down the
desktop on first boot.

## Before you wipe anything

**The age private key.** `~/.config/sops/age/keys.txt` is what decrypts your login password on the
new system, and it must reach the target before `nixos-install` (step 5).

Where it comes from depends on the disk choice below:

- **Keeping `/home` (this laptop's plan).** The key lives *on* the `/home` partition you are
  retaining, so it survives the install untouched — you copy it straight from the mounted partition
  in step 5, no USB round-trip. Nothing extra to do here.
- **Wiping the whole disk.** `/home` goes with it, so copy the key off the laptop first:
  `cp ~/.config/sops/age/keys.txt /run/media/wise/USB/keys.txt` (adjust the mount path).

Even keeping `/home`, a copy on a USB is cheap insurance worth taking: the key and everything else on
`/home` share one failure mode — `mkfs` on the wrong partition in step 1 — and a copy elsewhere is
the only thing that survives that. Losing the key is recoverable but tedious (generate a new one,
`sops updatekeys` against it, re-encrypt and commit — see [`README.md` → Secrets](../README.md#secrets)),
and you would be doing it from the installer. (This laptop's `/home` is plain ext4 — no LUKS unlock
to worry about.)

**Your real login password.** This is already set — `secrets.yaml` holds your `wise` login hash,
encrypted, and pushed. Nothing to do here unless you want to *change* it before installing, in which
case, from Manjaro:

```sh
# Type the new password; copy the $y$... line. -m yescrypt matches NixOS's default.
nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt

# Open the encrypted file in $EDITOR, replace the wise_password_hash value, save.
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  nix shell nixpkgs#sops -c sops hosts/wise-laptop/secrets.yaml
```

The value you paste is a hash, not the password, and the file is encrypted at rest — so commit and
push it. The installer clones this repo, so it must clone the version with the hash you want:

```sh
git add hosts/wise-laptop/secrets.yaml && git commit -m "secrets: rotate wise password" && git push
```

**Anything else you care about.** The repo and `~/dotfiles` are on GitHub; `~/dotfiles/local/` is
deliberately unsynced, so SSH keys, browser profiles and anything under it exist nowhere else. Back
up what you need.

## Disk layout — keeping /home

This laptop's disk was confirmed with `lsblk -f`; the plan keeps `/home` and reinstalls only the
system. **Re-run `lsblk -f` from the installer before touching anything** — device names can shift,
and this is the step with no undo.

| Partition | Size | Today | After install | Touched? |
| --- | --- | --- | --- | --- |
| `nvme0n1p1` | 512M | ESP, at `/boot/efi` | ESP, label `BOOT`, mounted at `/boot` | reformatted |
| `nvme0n1p2` | 2G | swap | swap, label `swap` | remade (contents are scratch) |
| `nvme0n1p3` | 89.3G | Manjaro `/` | root, ext4, label `nixos` | **reformatted — erased** |
| `nvme0n1p4` | 146.7G | `/home` | `/home`, label `home` | **kept — never formatted** |

The single rule: **`mkfs` runs on p1, p2 and p3, never on p4.** Everything under `/home` survives,
including `~/dotfiles`, which makes first-boot provisioning a near no-op — it finds the clone already
there and skips it.

Two things beyond "don't format p4":

- **Nothing is labelled today, and the config is entirely label-based** (`by-label/nixos`,
  `by-label/BOOT`, and the `home` label you mount by). So labelling every partition is a required
  step below, not a nicety. `e2label`/`fatlabel`/`mkswap -L` rename a label and, for `/home`, touch
  no file data — but label `/home` while it is **unmounted**.
- **Ownership needs a one-time fix.** `/home/wise` on this machine is owned `1000:1000` — uid 1000
  (which the config pins, so that half matches) but *group* 1000, Manjaro's per-user `wise` group.
  NixOS puts `wise` in the shared `users` group (gid 100), so every file's group would be wrong until
  corrected. This is not conditional here; it is a required step, run in step 7 below.

Back up `/home` anyway. A slip below — `mkfs` on p4 instead of p3 — erases it, and that is the one
mistake this runbook cannot undo. (Wiping the whole disk instead, `/home` and all, is the same steps
minus the "keep p4" care; it is not this laptop's plan and is not written out separately.)

`/home` is 81% full, and 40 GB of that is `/home/timeshift` — Manjaro's snapshots, which NixOS does
not use (it has boot generations instead). Once the new system is up and confirmed, `sudo rm -rf
/home/timeshift` reclaims the space; the step-7 `chown` leaves it alone (it is root-owned, and only
`/home/wise` is chowned).

## Install

Boot a recent NixOS installer USB (the minimal ISO is enough) and bring up the network — `iwctl` for
wifi, or plug in ethernet. Confirm the layout matches the table above:

```sh
lsblk -f          # p3 = Manjaro root to erase, p4 = /home to keep — be certain before mkfs
```

**1. Reformat the system partitions and label all four.** p4 (`/home`) is labelled but **not**
formatted; p1/p2/p3 are remade. Nothing here is mounted yet — the disk is idle under the installer.

```sh
mkfs.ext4 -L nixos    /dev/nvme0n1p3     # root — ERASES the old Manjaro system
mkfs.fat  -F32 -n BOOT /dev/nvme0n1p1    # ESP — Manjaro's boot entries go with it (intended)
mkswap    -L swap      /dev/nvme0n1p2    # swap — relabel/remake, contents are scratch
e2label   /dev/nvme0n1p4 home           # /home — LABEL ONLY, no mkfs, while unmounted
```

**2. Mount and enable swap** by label, exactly as the config will — all four, and *before*
`nixos-generate-config`, so the generator captures every one:

```sh
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=0077 /dev/disk/by-label/BOOT /mnt/boot
mkdir -p /mnt/home
mount /dev/disk/by-label/home /mnt/home     # the kept partition; never formatted
swapon /dev/disk/by-label/swap
```

**3. Generate the hardware config**, which is the only file this install writes that the repo does
not already carry:

```sh
nixos-generate-config --root /mnt
```

This writes `/mnt/etc/nixos/hardware-configuration.nix` describing *this* machine's disks and kernel
modules. The repo ships a placeholder for that file; you are about to replace it. Two edits to the
generated file before it goes in:

- **Reduce every `/dev/disk/by-uuid/…` to `by-label`.** `nixos-generate-config` names devices by
  UUID, and it will have written all four you mounted — the two `fileSystems` (`nixos`, `BOOT`), the
  `fileSystems."/home"` (because you mounted it in step 2), and a `swapDevices` entry (because swap
  was on). Rewrite each `device` to its label: `/dev/disk/by-label/{nixos,BOOT,home,swap}`. A
  committed UUID is what `check-privacy` rejects, and it fingerprints the machine.
- **Drop `configuration.nix`.** You do not need the generated `configuration.nix` at all — the flake
  is the configuration. Only the hardware file carries over.

**4. Get the flake and your hardware file onto the target.** This config lives on the
`feat/sops-nix-and-install-runbook` branch, not `main` — clone *that branch*, or you install a `main`
that has neither sops nor your password (it still carries `initialPassword = "changeme"`). Installing
off the branch first, then merging once it boots, is the intended order.

```sh
nix-shell -p git --run '
  git clone -b feat/sops-nix-and-install-runbook \
    https://github.com/tjwise99/WiseOS /mnt/etc/nixos/WiseOS'
cp /mnt/etc/nixos/hardware-configuration.nix \
   /mnt/etc/nixos/WiseOS/hosts/wise-laptop/hardware-configuration.nix
# now apply the two edits above to that copy
```

After the branch is merged, point the on-disk checkout back at `main` so later rebuilds track it:
`git -C /etc/nixos/WiseOS fetch origin && git -C /etc/nixos/WiseOS checkout main`.

Editing the tracked `hardware-configuration.nix` leaves the tree dirty, and `nixos-install` will
print `warning: Git tree '…' is dirty`. That is expected and correct — for a local git flake, Nix
evaluates the **working-tree** content of tracked files, so your edited hardware file (with the
`/home` and swap entries) is what gets installed, not the committed placeholder. No local commit is
needed. (If you would rather be certain, `git -C /mnt/etc/nixos/WiseOS add -A` before installing.)

**5. Place the age key** so the very first activation can decrypt your password. The keyFile path the
config reads is `/var/lib/sops-nix/key.txt`; under the installer that is `/mnt/var/lib/…`:

```sh
mkdir -p /mnt/var/lib/sops-nix

# Keeping /home (this laptop's plan): the key is on the partition you just
# mounted — copy it straight across, no USB needed.
cp /mnt/home/wise/.config/sops/age/keys.txt /mnt/var/lib/sops-nix/key.txt

# Wiped the whole disk instead: use the copy you saved off the laptop.
# cp /run/media/wise/USB/keys.txt /mnt/var/lib/sops-nix/key.txt

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

**7. Fix `/home/wise` ownership** (retained-`/home` only). The files carry Manjaro's `wise:wise`
group (gid 1000); NixOS puts `wise` in `users` (gid 100), so correct the group now, while the mount
is still at `/mnt`:

```sh
nixos-enter --root /mnt -c 'chown -R wise:users /home/wise'
```

## First boot

Reboot and remove the USB. Log in as `wise` with your password. Then prove the secret path did what
it claims — decrypted, and never in the store:

```sh
sudo test -f /run/secrets-for-users/wise_password_hash && echo "decrypted at boot: yes"
grep -rl "$(sudo cat /run/secrets-for-users/wise_password_hash)" /nix/store 2>/dev/null \
  && echo "LEAKED INTO STORE" || echo "not in store: good"
```

**Connect the network first.** iwd's saved wifi credentials lived on the old root, which you
reformatted — so this boot has no network until you re-add one. `dotfiles-provision` needs it (it
runs `dotfiles/install`, which fetches asdf runtimes), and it is a `oneshot` that retries for 90 s
then gives up for good, so bring the network up promptly:

```sh
iwctl station wlan0 connect <SSID>     # or just plug in ethernet
```

`dotfiles-provision` then runs `dotfiles/install` and restarts i3 so the bar and theme come up. On
this retained-`/home` install the `~/dotfiles` clone is already on `/home`, so the clone step is
skipped, but `install` still runs (its `~/.dotfiles-provisioned` marker is not there yet). Its remote
is still HTTPS, so `tools/sync.sh` cannot push until you switch it to SSH:

```sh
git -C ~/dotfiles remote set-url origin git@github.com:tjwise99/dotfiles.git
```

Until you do, the shell reports a sync failure at every prompt — the chosen trade, not a bug, and it
clears the moment the remote is SSH and a key exists.

## What is only testable here

The VM has no radio and no real GPU, so wifi, backlight, suspend and Intel graphics get their first
real exercise now. Do it from the installer USB if you can still boot it — iterating on a graphics or
suspend problem is far cheaper there than from a half-installed disk.
