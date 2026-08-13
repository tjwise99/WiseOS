#!/usr/bin/env bash
# Every check-* recipe is a dependency of `verify`.
#
# CI running `just verify` makes CI track the recipe, which is only worth
# anything if the recipe tracks the justfile. Without this, a check added and
# not wired into `verify` runs nowhere and nothing says so.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

defined=$(grep -oE '^check-[a-z0-9-]+:' justfile | tr -d ':' | sort -u)
wired=$(grep -E '^verify:' justfile | sed 's/^verify://' | tr ' ' '\n' | grep -v '^$' | sort -u)

if [ -z "$defined" ] || [ -z "$wired" ]; then
    echo 'check-recipes: parsed no recipes or no verify dependencies out of the justfile' >&2
    exit 1
fi

missing=$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$wired"))
if [ -n "$missing" ]; then
    printf 'check-recipes: defined but not run by verify:\n%s\n' "$missing" >&2
    exit 1
fi

printf 'check-recipes: all %d check recipes are wired into verify\n' "$(printf '%s\n' "$defined" | wc -l)"
