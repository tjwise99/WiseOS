#!/usr/bin/env bash
# Print the exact nixpkgs this flake is locked to, as a flakeref.
#
# Lint tooling is fetched through this rather than the `nixpkgs` registry, so a
# check runs against the same package set the configuration evaluates against
# and tracks flake.lock without a second thing to bump.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

jq -er '.nodes.nixpkgs.locked | "github:\(.owner)/\(.repo)/\(.rev)"' flake.lock
