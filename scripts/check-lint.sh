#!/usr/bin/env bash
# statix and deadnix, from the nixpkgs this flake is locked to.
#
# nixfmt is deliberately absent. It reports all four sources unformatted, and
# enforcing it would rewrite comment layout the sources use to explain
# themselves — a cost with no defect behind it.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

pin=$(scripts/nixpkgs-pin.sh) || {
    echo 'check-lint: cannot read the nixpkgs pin out of flake.lock' >&2
    exit 1
}

status=0

# repeated_keys is disabled in statix.toml: it objects to the flat
# `services.xserver.enable` style that NixOS configuration is written in.
nix run "${pin}#statix" -- check . || status=1
nix run "${pin}#deadnix" -- --fail . || status=1

[ "$status" -eq 0 ] && echo 'check-lint: statix and deadnix clean'
exit "$status"
