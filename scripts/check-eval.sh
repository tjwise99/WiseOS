#!/usr/bin/env bash
# Evaluate every flake output to a derivation path, without building one.
#
# Evaluation catches what this repo actually gets wrong: a misspelled option, a
# module that does not exist, the nixpkgs/home-manager version conflicts
# flake.nix already carries comments about. Building the closure costs an order
# of magnitude more wall clock and proves little past that; the build is
# exercised by `nixos-rebuild build-vm` locally.
#
# Output names are discovered, never listed. The set differs per branch, so a
# hardcoded list stops covering a host the moment one is added, and says
# nothing when it does.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

total=0
status=0

# $1 output attrset to enumerate, $2 path from an entry to its derivation
eval_group() {
    local group=$1 suffix=$2 names name drv

    if ! names=$(nix eval ".#${group}" --raw \
        --apply 'cfgs: builtins.concatStringsSep "\n" (builtins.attrNames cfgs)' 2>/dev/null); then
        printf 'no %s in this flake\n' "$group"
        return 0
    fi

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        total=$((total + 1))
        if drv=$(nix eval ".#${group}.${name}.${suffix}" --raw 2>&1); then
            printf '  ok    %s.%s -> %s\n' "$group" "$name" "${drv##*/}"
        else
            printf '  FAIL  %s.%s\n%s\n' "$group" "$name" "$drv" >&2
            status=1
        fi
    done <<<"$names"
}

eval_group homeConfigurations activationPackage.drvPath
eval_group nixosConfigurations config.system.build.toplevel.drvPath

# The guard that carries this check. Discovery returning nothing would run zero
# evaluations and exit 0 — identical, from the outside, to everything passing.
if [ "$total" -eq 0 ]; then
    echo 'check-eval: discovery found no flake outputs, so nothing was evaluated' >&2
    exit 1
fi

printf 'check-eval: %d output(s) evaluated\n' "$total"
exit "$status"
