#!/usr/bin/env bash
# Reject machine-identifying detail in a publicly published configuration.
#
# gitleaks and GitHub's scanner both match credential *shapes*. A disk UUID, a
# MAC address, an SSID or a WPA passphrase are none of those, and in a NixOS
# config published to a public repository they are the exposure that actually
# matters — together they fingerprint a machine and the network it sits on.
# Two of them leak twice, because Nix copies them world-readable into
# /nix/store as well.
#
# This is a backstop and fails open by construction: a denylist cannot see a
# shape nobody listed. The structural fix is encrypting secrets at rest with
# sops-nix, which is tracked separately.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

status=0

# Tracked files only, and never this file — it necessarily contains every
# pattern it searches for.
self='scripts/check-privacy.sh'

scan() {
    local label=$1 pattern=$2 hits
    hits=$(git grep -nIE -e "$pattern" -- . ":(exclude)${self}" || true)
    if [ -n "$hits" ]; then
        printf 'check-privacy: %s\n%s\n\n' "$label" "$hits" >&2
        status=1
    fi
}

scan 'disk or filesystem UUID — name the device by label instead' \
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

scan 'MAC address' \
    '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'

scan 'wireless pre-shared key' \
    '\bpsk(Raw)?[[:space:]]*='

scan 'wireless network block — carries an SSID' \
    'wireless\.networks'

scan 'password hash' \
    '\b(initialHashedPassword|hashedPassword)[[:space:]]*='

scan 'private IPv4 address' \
    '(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})'

# initialPassword is legitimate here — it seeds a VM account that has none yet,
# and the config documents replacing it at first login. Only a value that is
# not an obvious placeholder is a finding.
seeds=$(git grep -nIE -e 'initialPassword[[:space:]]*=' -- . ":(exclude)${self}" || true)
real=$(printf '%s' "$seeds" | grep -vE '"(changeme|nixos)"' || true)
if [ -n "$real" ]; then
    printf 'check-privacy: initialPassword set to something other than a placeholder\n%s\n\n' \
        "$real" >&2
    status=1
fi

[ "$status" -eq 0 ] && echo 'check-privacy: no machine-identifying detail found'
exit "$status"
