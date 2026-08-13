#!/usr/bin/env bash
# Reject machine-identifying detail in a publicly published configuration.
#
# gitleaks and GitHub's scanner both match credential *shapes*. A disk UUID, a
# MAC address, an SSID or a wireless passphrase are none of those, and in a
# NixOS config published to a public repository they are the exposure that
# actually matters — together they fingerprint a machine and its network. Two
# of them leak twice, because Nix copies them world-readable into /nix/store
# as well.
#
# This is a backstop and fails open by construction: a denylist cannot see a
# shape nobody listed. The structural fix is encrypting secrets at rest with
# sops-nix, tracked as issue #4.
#
# A line ending `# privacy-ok: <reason>` is exempt. Published constants share
# shapes with private ones — a Bluetooth service UUID and a disk UUID are both
# 8-4-4-4 hex — so blocking outright would reject legal input. The marker keeps
# each exemption one reviewable line in the diff rather than a pattern change.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

# Carries one specimen of every shape below. Scanned separately as a positive
# control, and excluded from the real scan so it is not its own finding.
fixture='tests/privacy-fixture.txt'

# Value shapes, meaningful in any file.
value_labels=(
    'disk or filesystem UUID — name the device by label instead'
    'MAC address'
    'private IPv4 address'
)
value_patterns=(
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
    '(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
)

# Option assignments, meaningful only in Nix. Naming one in prose is not a leak.
# The wireless set covers wpa_supplicant (psk/pskRaw), iwd (Passphrase=, which
# is what this host actually runs), hostapd (wpaPassword) and the plaintext
# users.users.<n>.password.
option_labels=(
    'wireless passphrase or pre-shared key'
    'wireless network block — carries an SSID'
    'plaintext password option'
    'password hash — publish the file reference, not the hash'
)
option_patterns=(
    '(\bpsk|pskRaw|wpa_psk|[Pp]assphrase|wpaPassword)[[:space:]]*='
    '(wireless\.networks\.|[Ss]sid[[:space:]]*=)'
    '\bpassword[[:space:]]*='
    '\b(initialHashedPassword|hashedPassword)[[:space:]]*='
)

status=0

# Strip exempted lines. Kept out of the git grep pattern so the marker shows up
# in the hit list of anything it is suppressing when read by eye.
#
# `= "!"` and `= null` are dropped unconditionally: they are how NixOS locks an
# account, and they carry no secret by construction. Firing there would fire
# precisely when someone hardens the config, and issue #4 reads a false
# positive here as the signal to adopt sops-nix.
drop_exempt() {
    grep -vE '# privacy-ok:|=[[:space:]]*(null|"!"|"\*")[[:space:]]*;?[[:space:]]*$' || true
}

report() {
    printf 'check-privacy: %s\n%s\n\n' "$1" "$2" >&2
    status=1
}

scan_set() {
    local -n labels=$1 pats=$2
    local i hits raw
    shift 2
    for i in "${!pats[@]}"; do
        raw=$(git grep -nIE -e "${pats[$i]}" -- "$@" || true)
        hits=$(printf '%s' "$raw" | drop_exempt)
        [ -n "$hits" ] && report "${labels[$i]}" "$hits"
    done
}

# --- the real scan ------------------------------------------------------
scan_set value_labels value_patterns . ":(exclude)${fixture}"
scan_set option_labels option_patterns '*.nix' ":(exclude)${fixture}"

# initialPassword seeds a VM account that has none yet, and the config
# documents replacing it at first login. Test the assigned *value*: matching
# the whole grep line lets a comment or a sibling attribute mentioning the
# placeholder suppress a real password on the same line.
seeds=$(git grep -nIE -e 'initialPassword[[:space:]]*=' -- '*.nix' ":(exclude)${fixture}" || true)
seeds=$(printf '%s' "$seeds" | drop_exempt)
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    value=$(printf '%s' "$hit" | sed -nE 's/.*initialPassword[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p')
    [ "$value" = changeme ] && continue
    report 'initialPassword set to something other than the documented placeholder' "$hit"
done <<<"$seeds"

# --- positive control ---------------------------------------------------
# Without this, a run over a tree missing home/ and hosts/ — a sparse checkout,
# a bad pathspec, a rename — prints exactly what a clean scan prints.
missed=()
for i in "${!value_patterns[@]}"; do
    git grep -qIE -e "${value_patterns[$i]}" -- "$fixture" || missed+=("${value_labels[$i]}")
done
for i in "${!option_patterns[@]}"; do
    git grep -qIE -e "${option_patterns[$i]}" -- "$fixture" || missed+=("${option_labels[$i]}")
done
if [ ${#missed[@]} -gt 0 ]; then
    printf 'check-privacy: %s is not tracked, or no longer exercises: %s\n' \
        "$fixture" "$(printf '%s; ' "${missed[@]}")" >&2
    exit 1
fi

[ "$status" -eq 0 ] && printf 'check-privacy: clean; %d patterns exercised against %s\n' \
    "$(( ${#value_patterns[@]} + ${#option_patterns[@]} ))" "$fixture"
exit "$status"
