# WiseOS

NixOS and Home Manager configuration for the laptop, built and tested from the Manjaro install it
is eventually meant to replace.

The point of the layout is that nothing here has to wait for a NixOS machine to exist. Home Manager
runs against Manjaro today, and `nixos-rebuild build-vm` boots the full system config in QEMU from
the same flake. When the metal install happens, the only file that changes is
`hosts/wise-laptop/hardware-configuration.nix` — and `nixos-generate-config` writes that file with
`/dev/disk/by-uuid/` devices, which `just check-privacy` rejects. Reduce them to labels, as the
placeholder already does, before committing it.

## Why this is not in `dotfiles`

The obvious move is a `nix/` directory inside [`dotfiles`](https://github.com/tjwise99/dotfiles),
and that repo is where this will probably end up. It is separate for now because that repo is
shared with a WSL box, and sharing has a cost during the phase where things are half-written:

- `tools/sync.sh` runs on a 20-minute timer on **both** machines, and rebases each onto the other.
  Files added here would land on the WSL box within 20 minutes. Nothing would *execute* — sync does
  git operations only, and never runs `./install` — but the files arrive regardless.
- That sync also runs `tools/check-manifest.py --deployed`, which asserts every tracked file is
  deployed by some profile. Nix config is read by `nix`, not symlinked into `$HOME`, so it fails
  that gate. A failure writes `~/.dotfiles-sync-failed`, which `shell/interactive.sh` prints at
  every new shell — on the WSL box, without anyone touching it.
- A flake in a repo that auto-commits every 20 minutes publishes half-written expressions and
  churns `flake.lock`.

None of that is hard to fix — `nix` joins `EXEMPT_DIRS` in the manifest gate, and Nix steps stay out
of `profiles/base.conf.yaml` so the WSL host never runs them. It just buys nothing yet. The
argument for cohousing is atomic commits when a package moves from `packages/manifest.yaml` to
`home.packages`, and that does not apply until things actually start moving. `git subtree add
--prefix=nix` folds this in later with history intact.

## Layout

| Path | Contents |
| --- | --- |
| `flake.nix` | Inputs and the two outputs, sharing one nixpkgs pin |
| `home/wise.nix` | Home Manager — runs on Manjaro now, carries over to NixOS |
| `hosts/wise-laptop/` | The system config, and the hardware file the installer regenerates |
| `justfile`, `scripts/` | The checks, and `just verify` — the one recipe CI runs |

## The two outputs

Both evaluate against the same `nixpkgs`, so what is proved in one is true in the other.

```sh
home-manager switch --flake .#wise          # apply to the running Manjaro install
nixos-rebuild build-vm --flake .#wise-laptop # build a bootable QEMU VM, then ./result/bin/run-*-vm
```

`nixos-rebuild build-vm` needs no NixOS and no root. The QEMU module overrides `fileSystems` with
`mkVMOverride`, which is why the placeholder devices in `hardware-configuration.nix` do not matter
in a VM.

## Checks

`just verify` — CI runs this one recipe, so the two cannot drift. `just --list` names each check.

Nothing builds. Every output is evaluated to a derivation path, which catches a misspelled option or
a missing module in about a minute; the build itself is exercised by `nixos-rebuild build-vm` above.
Output names are discovered rather than listed, so a host added to `flake.nix` is covered without
touching the check.

`check-privacy` is the one worth knowing about, because this repo is public and a credential scanner
cannot see what leaks here: a disk UUID, an SSID or a wireless passphrase is not credential-shaped,
and together they fingerprint a machine and its network.

**Run `just check-privacy` for what it enforces — it prints every check by name.** No list is kept
here on purpose. Nothing compares a list in this file to the patterns in the script, so a copy goes
stale the first time a pattern is added, with nothing to say so; a review of this repo found the
justfile and this README had already drifted apart from the script in different directions, each
omitting the one credential the config actually contains.

It is a denylist and fails open on anything nobody listed. The control that does not depend on a
pattern — a secret with a correct encrypted home rather than a shape to be caught — is now in place
with sops-nix; see [Secrets](#secrets).

## Secrets

`sops-nix` encrypts secrets at rest in the repo and decrypts them at activation into `/run` — never
into the world-readable `/nix/store`, and never as plaintext in a committed file. Today there is one:
`wise_password_hash`, the `wise` account's login hash, in `hosts/wise-laptop/secrets.yaml`.

One age key does three jobs, and its private half is in the repo for none of them. It lives at
`~/.config/sops/age/keys.txt` on this dev host, where the `sops` CLI uses it to edit the repo; the
QEMU VM does not get it (see below); and on metal it is placed at `/var/lib/sops-nix/key.txt` at
install time, which is where the running system reads it. `.sops.yaml` records only the *public* key.

```sh
# Edit or add a secret (opens the decrypted file in $EDITOR, re-encrypts on save):
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  nix shell nixpkgs#sops -c sops hosts/wise-laptop/secrets.yaml

# Re-wrap every secret for a changed recipient list in .sops.yaml (no plaintext exposed):
nix shell nixpkgs#sops -c sops updatekeys hosts/wise-laptop/secrets.yaml
```

The committed hash is a **placeholder** — the hash of `changeme` — so the flake evaluates and the VM
builds without anyone's real password. Replacing it with a real one is the first step of
[`docs/install.md`](docs/install.md), done before the config reaches metal.

The password is a per-user secret, so it is decrypted *before* users are created
(`neededForUsers`), a phase that runs before systemd has mounted anything. That is why the VM cannot
be handed the key over a share and keeps `initialPassword = "changeme"` instead: the metal first boot
is where this path runs for real, and `docs/install.md` verifies it there.

## Installing on metal

[`docs/install.md`](docs/install.md) is the runbook: what to save before wiping, the disk-layout
decision (wipe vs dual-boot on the 512 M ESP), partitioning to the `nixos`/`BOOT` labels the config
names, placing the age key, and the first-boot verification that the password decrypted without
reaching the store.

## Home Manager owns packages, not files

`home/wise.nix` sets `home.packages` and nothing else, on purpose.

Every dotfile in `$HOME` is a Dotbot symlink into `~/dotfiles` — 29 of them. Home Manager wants to
own those same paths and refuses to clobber files it did not create, so a `programs.*` block that
writes config would contend with Dotbot for the same target. Migrating a path is a deliberate,
one-at-a-time change: add the Home Manager module *and* remove the link from
`profiles/base.conf.yaml` in the same commit. Until then, Dotbot owns files and Nix owns packages,
and the boundary is clean.

`targets.genericLinux.enable` is what makes this work on a non-NixOS host — it fixes up
`XDG_DATA_DIRS` and the session variables so packages contribute man pages, icons and `.desktop`
entries to a system Nix did not build.

## Pinning

`nixpkgs` is `nixos-26.05` and `home-manager` is `release-26.05`. These move together — a Home
Manager release tracks a nixpkgs release, and crossing them is the ordinary cause of evaluation
errors. `home-manager` follows this flake's `nixpkgs` so only one package set is ever in play.

`stateVersion` in both configs records the release whose defaults they were written against. It is
not a version to bump for freshness; changing it opts into changed stateful defaults.

## Nix on Manjaro

Installed from Manjaro's `extra` repo rather than the upstream installer, so it is declared the same
way every other package on that host is. Two things the package does not do on its own:

- `/nix/store` and the database do not exist until `nix-store --init` is run as root. The shipped
  tmpfiles config creates only the socket and build directories.
- Flakes and the new CLI are off by default; `/etc/nix/nix.conf` needs
  `experimental-features = nix-command flakes`.

There is no `nix-users` group on Arch — the daemon socket is mode `0666`, so any user can connect
once `nix-daemon.socket` is enabled.

Reversible with `pacman -R nix && sudo rm -rf /nix /etc/nix`.

## First boot

`systemd.services.dotfiles-provision` clones [`dotfiles`](https://github.com/tjwise99/dotfiles) and
runs its `./install` once, guarded by `~/.dotfiles-provisioned`. A failure leaves that marker
unwritten, so the next boot retries rather than the machine being stuck half-configured.

It is a unit of its own rather than a `home.activation` step, because `home-manager-wise.service`
has `TimeoutStartSec=5m` and asdf compiles Rust and Go — activation would be killed mid-build. It
clones over **HTTPS**, because a fresh machine has no SSH keys (`local/` is deliberately unsynced),
which means `tools/sync.sh` cannot push until the remote is switched:

```sh
git -C ~/dotfiles remote set-url origin git@github.com:tjwise99/dotfiles.git
```

Until then the shell reports a sync failure at every prompt. That is the chosen trade, not a bug.

## What NixOS does not give you

Everything below was found by booting this config, and each one reads as a broken desktop rather
than a missing declaration. They are recorded because the symptom never resembles the cause.

**There is no baseline.** Manjaro's ISO supplied i3, polybar, picom, rofi, dunst, alacritty, X and
lightdm implicitly — none of them appear in `dotfiles/packages/manifest.yaml`, whose `manjaro:` tier
is empty. On NixOS nothing exists undeclared, so the desktop package list had to be *derived* from
the exec targets in `i3/config`, and the fonts from what the theme templates name by string. That
discovery is the real cost of the move, and most of its value.

**A `shell:` step does not inherit the unit's PATH.** dotbot runs them with `$SHELL`, systemd sets
`$SHELL` from the declared login shell, and NixOS's `/etc/zshenv` sources `/etc/set-environment`,
which **assigns** `PATH` rather than extending it. So anything a `shell:` step needs must be in
`environment.systemPackages`; the unit's own `path` only covers `./install` itself and the clone.
The symptom was `python3: command not found` from a unit whose PATH demonstrably contained it.

**asdf ships binaries NixOS cannot run.** Its Node asks for `/lib64/ld-linux-x86-64.so.2`, which
does not exist. `programs.nix-ld.enable` supplies a loader; its default library set already covers
`libstdc++` and `libgcc`. Keeping asdf rather than moving runtimes to Nix is deliberate — asdf is
what gives the laptop and the WSL box one pinned version, and migrating only this host breaks that
parity.

**The session beats provisioning, so i3 loads the wrong config.** Autologin starts i3 while
`dotfiles-provision` is still compiling, before `~/.config/i3` exists, so i3 falls back to the
packaged config — no bar, no theme, and nothing to run `theme/session.sh` until the next login. The
unit restarts i3 once the tree is in place. `restart`, not `reload`: reload re-reads the file i3
already loaded, which is the store path, so it changes nothing while appearing to work.

**A hardcoded output name is fatal, not cosmetic.** `theme/polybar.ini.tmpl` named `eDP-1`; polybar
exits with `Monitor not found or disconnected` rather than falling back, so the bar is absent
entirely. Fixed upstream in dotfiles as `${env:MONITOR:}`.

**Compositing on an emulated GPU is unusable.** The VM runner passes QEMU no video device at all.
`-vga qxl` helps and is not enough; `i3/picom-launch.sh` now skips under `systemd-detect-virt`.

## Open

- **The committed password hash is a placeholder** — the hash of `changeme`, encrypted so the flake
  evaluates. It becomes a real login only after you replace it with your own, which is step one of
  [`docs/install.md`](docs/install.md). The plaintext-`initialPassword` exposure that used to sit
  here is closed: metal reads `hashedPasswordFile` from the sops secret, and `check-privacy` still
  rejects an inline hash. See [Secrets](#secrets).
- Wifi, backlight, suspend and Intel graphics remain untested: a VM has no radio and no real GPU.
  Their first real test is on hardware, from the installer USB where iterating is still possible.
