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
# It prints what it enforced, so this script is the inventory and no document
# has to carry a second copy of the list to fall out of step with.
#
# A line carrying a privacy-ok marker (see the regex below) plus a reason is
# exempt. Published constants share shapes with private ones — a Bluetooth
# service UUID is 8-4-4-4 hex too — so blocking outright would reject legal
# input. Exemptions are counted and printed, because a silent bypass is the
# thing this file exists to not be.
#
# Nothing here may spell a pattern the way a config would. There is no
# self-exclusion — an earlier revision had one, justified by a claim that was
# false — so a literal example written into a comment is a finding against this
# file, correctly.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

fixture='tests/privacy-fixture.txt'

# Value shapes: meaningful in any file, prose included.
value_scope=(.)
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

# Assignments: skipped in Markdown, where naming an option is prose rather than
# a leak. Everywhere else, not just *.nix — this host's wireless secret would
# live in an iwd `.psk` or a `wpa_supplicant.conf`, neither of which is Nix.
#
# No leading \b anywhere: a preceding underscore or quote defeats the boundary,
# so an underscore-prefixed or quoted attribute name would pass. Matching each
# literal as a substring instead also covers the underscored wpa spelling.
option_scope=(. ':(exclude)*.md')
option_labels=(
    'wireless passphrase or pre-shared key'
    'wireless network block or SSID'
    'plaintext password option'
    'password hash — publish the file reference, not the hash'
)
option_patterns=(
    '(psk(Raw)?|[Pp]assphrase|wpaPassword)"?[[:space:]]*='
    '(wireless\.networks|[Ss][Ss][Ii][Dd]"?[[:space:]]*=)'
    'password"?[[:space:]]*='
    '(initialHashedPassword|hashedPassword)"?[[:space:]]*='
)

status=0

# Assembled rather than written out, so this file does not contain the marker
# in the form it matches and count itself as an exemption. Reason required:
# a bare marker exempts nothing.
marker_re="# $(printf 'privacy')-ok:[[:space:]]*[^[:space:]]"

# `= "!"`, `= "*"` and `= null` are how NixOS locks an account and carry no
# secret. Firing there would fire precisely when the config is hardened.
drop_exempt() {
    local kept
    kept=$(grep -vE "${marker_re}|=[[:space:]]*(null|\"!\"|\"\\*\")[[:space:]]*;?[[:space:]]*\$" || true)
    printf '%s' "$kept"
}

report() {
    printf 'check-privacy: %s\n%s\n\n' "$1" "$2" >&2
    status=1
}

scan_set() {
    local -n labels=$1 pats=$2 scope=$3
    local i raw hits
    for i in "${!pats[@]}"; do
        raw=$(git grep -nIE -e "${pats[$i]}" -- "${scope[@]}" ":(exclude)${fixture}" || true)
        hits=$(printf '%s' "$raw" | drop_exempt)
        if [ -n "$hits" ]; then
            report "${labels[$i]}" "$hits"
        else
            printf '  ok  %s\n' "${labels[$i]}"
        fi
    done
}

scan_set value_labels value_patterns value_scope
scan_set option_labels option_patterns option_scope

# initialPassword seeds a VM account that has none yet, and the config
# documents replacing it at first login. Test the assigned *value*: matching
# the whole grep line lets a comment or a sibling attribute mentioning the
# placeholder suppress a real password on the same line.
seeds=$(git grep -nIE -e 'initialPassword"?[[:space:]]*=' -- "${option_scope[@]}" ":(exclude)${fixture}" || true)
seeds=$(printf '%s' "$seeds" | drop_exempt)
bad=''
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    value=$(printf '%s' "$hit" | sed -nE 's/.*initialPassword"?[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p')
    [ "$value" = changeme ] && continue
    bad+="${hit}"$'\n'
done <<<"$seeds"
if [ -n "$bad" ]; then
    report 'initialPassword set to something other than the documented placeholder' "${bad%$'\n'}"
else
    printf '  ok  initialPassword is absent or the documented placeholder\n'
fi

# Positive control. Each pattern must match the fixture *through the same
# pathspec the real scan uses* — so a broken scope fails here rather than
# quietly scanning nothing. Asserting the pattern alone would not: the fixture
# would still match while the real scan reached no files at all.
missed=()
control() {
    local -n labels=$1 pats=$2 scope=$3
    local i files
    for i in "${!pats[@]}"; do
        files=$(git grep -lIE -e "${pats[$i]}" -- "${scope[@]}" || true)
        case $'\n'"$files"$'\n' in
            *$'\n'"$fixture"$'\n'*) ;;
            *) missed+=("${labels[$i]}") ;;
        esac
    done
}
control value_labels value_patterns value_scope
control option_labels option_patterns option_scope
# Not `| grep -q`: grep exits on the first hit, git grep takes SIGPIPE and dies
# 141, and pipefail returns that — false exactly when the pattern matches.
ip_files=$(git grep -lIE -e 'initialPassword"?[[:space:]]*=' -- "${option_scope[@]}" || true)
case $'\n'"$ip_files"$'\n' in
    *$'\n'"$fixture"$'\n'*) ;;
    *) missed+=('initialPassword') ;;
esac

if [ ${#missed[@]} -gt 0 ]; then
    printf 'check-privacy: %s is untracked, or the scan pathspec no longer reaches it; unexercised: %s\n' \
        "$fixture" "${missed[*]}" >&2
    exit 1
fi

exemptions=$(git grep -cIE -e "$marker_re" -- . || true)
[ -n "$exemptions" ] && printf 'check-privacy: exemptions in force:\n%s\n' "$exemptions"

[ "$status" -eq 0 ] && printf 'check-privacy: clean; %d checks, all exercised against %s\n' \
    "$(( ${#value_patterns[@]} + ${#option_patterns[@]} + 1 ))" "$fixture"
exit "$status"
