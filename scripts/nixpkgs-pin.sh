#!/usr/bin/env bash
# Print the exact nixpkgs this flake is locked to, as a flakeref.
#
# Lint tooling is fetched through this rather than the `nixpkgs` registry, so a
# check runs against the same package set the configuration evaluates against
# and tracks flake.lock without a second thing to bump.
#
# The fields are validated in jq rather than interpolated blind: `jq -e` fails
# only on a null or false *result*, and "github:\(.owner)" of a null owner is
# the truthy string "github:null" — which would reach `nix run` and fail there,
# several files from the cause.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

jq -er '
  .nodes.nixpkgs.locked
  | if .type != "github" then
      error("nixpkgs is locked to type \(.type), and this only builds a github: ref")
    elif (.owner == null or .repo == null or .rev == null) then
      error("nixpkgs lock entry is missing owner, repo or rev")
    else
      "github:\(.owner)/\(.repo)/\(.rev)"
    end
' flake.lock
