#!/usr/bin/env bash
# Evaluate every flake output to a derivation path, without building one.
#
# Evaluation catches what this repo actually gets wrong: a misspelled option, a
# module that does not exist, the nixpkgs/home-manager version conflicts
# flake.nix already carries comments about. Building the closure costs an order
# of magnitude more wall clock and proves little past that; the build is
# exercised by `nixos-rebuild build-vm` locally.
#
# Names within a group are discovered, so a host added to flake.nix is covered
# without touching this file. The groups themselves carry a floor, because
# discovery is silent in the other direction: an emptied or deleted group would
# otherwise evaluate nothing and report success.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

status=0
err_file=$(mktemp) || exit 1
trap 'rm -f "$err_file"' EXIT

# $1 output attrset, $2 path from an entry to its derivation, $3 minimum entries
eval_group() {
    local group=$1 suffix=$2 floor=$3 names name drv err count=0

    if ! names=$(nix eval ".#${group}" --raw \
        --apply 'cfgs: builtins.concatStringsSep "\n" (builtins.attrNames cfgs)' 2>"$err_file"); then
        err=$(cat "$err_file")
        # Nix exits non-zero both for an output the flake does not define and
        # for one that fails to evaluate. Only the first is absence; treating
        # the second as absence reports a broken flake as a pass. Anything not
        # recognised as absence is an error, so an unfamiliar message fails
        # closed rather than reading as an empty group.
        case $err in
            *"does not provide attribute"*)
                printf '  FAIL  %s is absent; its floor is %d\n' "$group" "$floor" >&2
                status=1
                return 0
                ;;
        esac
        printf '  FAIL  %s could not be enumerated\n%s\n' "$group" "$err" >&2
        status=1
        return 0
    fi

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        count=$((count + 1))
        if drv=$(nix eval ".#${group}.${name}.${suffix}" --raw 2>"$err_file"); then
            printf '  ok    %s.%s -> %s\n' "$group" "$name" "${drv##*/}"
        else
            printf '  FAIL  %s.%s\n%s\n' "$group" "$name" "$(cat "$err_file")" >&2
            status=1
        fi
    done <<<"$names"

    if [ "$count" -lt "$floor" ]; then
        printf '  FAIL  %s evaluated %d, below its floor of %d\n' "$group" "$count" "$floor" >&2
        status=1
        return 0
    fi
    printf '  %s: %d evaluated (floor %d)\n' "$group" "$count" "$floor"
}

eval_group homeConfigurations activationPackage.drvPath 1
eval_group nixosConfigurations config.system.build.toplevel.drvPath 1

exit "$status"
