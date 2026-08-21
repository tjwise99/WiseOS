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
# shape nobody listed. Secrets that belong encrypted now have that structural
# control — sops-nix, in hosts/wise-laptop/secrets.yaml, decrypted at activation
# and never written to the store — and check-sops asserts those files are fully
# encrypted rather than trusting they are. What backs this backstop is a secret
# having a correct home to be in; this scan still catches a loose hash typed
# into a committed file, which sops cannot prevent.
#
# It prints every check by name, so this script is the inventory and no
# document has to carry a second copy to fall out of step with.
#
# ONE SHAPE PER CHECK, NEVER AN ALTERNATION. The control below asserts each
# check matches the fixture; an alternation would satisfy that on one branch
# while the others were dead, deleted or wrong. Four branches went unguarded
# that way. A new shape gets a new entry and a new specimen, not a `|`.
#
# NOTHING HERE MAY SPELL A PATTERN THE WAY A CONFIG WOULD. There is no
# self-exclusion — an earlier revision had one, justified by a claim that was
# false — so a literal example in a comment is a finding against this file,
# correctly. The marker regex is assembled at runtime for the same reason.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

fixture='tests/privacy-fixture.txt'

# Value shapes: meaningful in any file, prose included.
value_scope=(.)

# Assignments: skipped in Markdown, where naming an option is prose rather than
# a leak. Everywhere else, not just Nix — this host's wireless secret would live
# in an iwd `.psk` or a `wpa_supplicant.conf`, neither of which is Nix.
option_scope=(. ':(exclude)*.md')

# key|label|regex. The key is what an exemption marker must name, so a line
# waved through for one shape cannot silently hide a different one later.
value_checks=(
  'uuid|disk or filesystem UUID — name the device by label instead|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  # A FAT/vfat volume serial — the ESP identifier nixos-generate-config emits,
  # `XXXX-XXXX`, which the full-UUID shape above is too long to catch. Bounded
  # by non-hex-non-dash so it cannot match a four-hex run inside a real UUID,
  # whose groups are dash-delimited.
  'fatserial|FAT volume serial — name the ESP by label instead|(^|[^0-9A-Fa-f-])[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}([^0-9A-Fa-f-]|$)'
  'mac-colon|MAC address, colon-separated|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
  'mac-dash|MAC address, dash-separated|([0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}'
  'ipv4-10|private IPv4, RFC1918 ten-dot range|(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-192|private IPv4, RFC1918 192.168 range|(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-172|private IPv4, RFC1918 172.16-31 range|(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-cgnat|CGNAT 100.64-127 range — a tailnet address names a specific machine|(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-linklocal|link-local 169.254 range|(^|[^0-9.])169\.254\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv6-ula|IPv6 unique local address, fd00::/8|(^|[^0-9a-fA-F:])fd[0-9a-fA-F]{2}:[0-9a-fA-F]{0,4}:[0-9a-fA-F:]+'
  # A plaintext unix password hash, matched by its Modular Crypt structure —
  # `$id$…$<blob>` with a long trailing digest — not by enumerating schemes, so
  # yescrypt, sha512crypt and bcrypt are one shape rather than a `|` list. This
  # is a value check (scans prose too): a hash pasted into a doc or written into
  # a `pkgs.writeText` leaks the same as one in a .nix option, and the =-keyed
  # option checks below miss both. sops ENC[] blobs carry no `$`, so an
  # encrypted secret does not match. Full-file encryption is check-sops's job;
  # this catches the loose hash that never went near a secrets file.
  'crypthash|plaintext unix password hash — publish the encrypted file reference, not the hash|\$[1-9a-z]{1,10}\$[A-Za-z0-9=,./+_-]{1,}\$[A-Za-z0-9./+]{16,}'
)

option_checks=(
  'psk|wireless pre-shared key|psk"?[[:space:]]*='
  'pskraw|wireless pre-shared key, raw|pskRaw"?[[:space:]]*='
  'passphrase|wireless passphrase — how iwd spells it|[Pp]assphrase"?[[:space:]]*='
  'wpapassword|hostapd wpaPassword|wpaPassword"?[[:space:]]*='
  'wireless-networks|wireless network block — carries an SSID|wireless\.networks'
  'ssid|SSID assignment|[Ss][Ss][Ii][Dd]"?[[:space:]]*='
  'password|plaintext password option|password"?[[:space:]]*='
  'hashedpassword|password hash — publish the file reference, not the hash|hashedPassword"?[[:space:]]*='
  'initialhashedpassword|initial password hash|initialHashedPassword"?[[:space:]]*='
)

status=0

# Assembled so this file does not contain the marker in the form it matches.
# Requires a reason, and requires the marker to run to end of line with no
# quote after it — otherwise a marker inside a Nix string value would exempt
# the value it sits in, which is not a comment at all.
mk="$(printf 'privacy')-ok"
marker_of() { printf '#[[:space:]]*%s\\[%s\\]:[[:space:]]*[^"[:space:]][^"]*$' "$mk" "$1"; }

# The marker's spelling appears in no file — deliberately, since a file the scan
# reads cannot contain it. So the finding carries it, keyed and ready to paste:
# the only moment anyone needs it is the moment they are reading this.
#
# A hit in this file is the constraint above biting. The obvious repair is a
# marker, which is the one repair that must not happen here — it would rebuild
# the per-line self-exclusion this file must not have — so the finding names the
# right one instead.
self='scripts/check-privacy.sh'
report() {
    local label=$1 key=$2 hits=$3
    printf 'check-privacy: %s\n%s\n' "$label" "$hits" >&2
    printf '  exempt one line by ending it with: # %s[%s]: <reason>\n' "$mk" "$key" >&2
    case $hits in
        *"$self"*) printf '  %s is scanned like every other file. Put literal examples in %s, which is excluded from the scan — do not exempt a line here.\n' "$self" "$fixture" >&2 ;;
    esac
    printf '\n' >&2
    status=1
}

# `= "!"`, `= "*"` and `= null` lock an account and carry no secret. Applied
# only to the hash checks: no UUID, MAC or address can legitimately hold those
# values, so widening it elsewhere would buy nothing and swallow a real finding
# sharing a line with an unrelated null.
lock_re='=[[:space:]]*(null|"!"|"\*")[[:space:]]*;?[[:space:]]*$'

run_checks() {
    local -n checks=$1 scope=$2
    local entry key label pat raw hits
    for entry in "${checks[@]}"; do
        IFS='|' read -r key label pat <<<"$entry"
        raw=$(git grep -nIE -e "$pat" -- "${scope[@]}" ":(exclude)${fixture}" || true)
        hits=$(printf '%s' "$raw" | { grep -vE "$(marker_of "$key")" || true; })
        case $key in
            hashedpassword|initialhashedpassword|password)
                hits=$(printf '%s' "$hits" | { grep -vE "$lock_re" || true; }) ;;
        esac
        if [ -n "$hits" ]; then report "$label" "$key" "$hits"; else printf '  ok  %s\n' "$label"; fi
    done
}

run_checks value_checks value_scope
run_checks option_checks option_scope

# initialPassword seeds a VM account that has none yet, and the config
# documents replacing it at first login. Every assignment on the line is
# tested, not one: a greedy match takes the last, so a placeholder later on the
# line would mask a real password earlier on it.
ip_assign='initialPassword"?[[:space:]]*='
seeds=$(git grep -nIE -e "$ip_assign" -- "${option_scope[@]}" ":(exclude)${fixture}" || true)
seeds=$(printf '%s' "$seeds" | { grep -vE "$(marker_of initialpassword)" || true; })
bad=''
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    n_assign=$(printf '%s' "$hit" | grep -oE "$ip_assign" | wc -l)
    n_ok=$(printf '%s' "$hit" | grep -oE "${ip_assign}[[:space:]]*\"changeme\"" | wc -l)
    [ "$n_assign" -eq "$n_ok" ] && continue
    bad+="${hit}"$'\n'
done <<<"$seeds"
if [ -n "$bad" ]; then
    report 'initialPassword set to something other than the documented placeholder' \
        initialpassword "${bad%$'\n'}"
else
    printf '  ok  initialPassword is absent or the documented placeholder\n'
fi

# Positive control. Each check must match the fixture *through the pathspec its
# own scan uses*, so a broken scope fails here rather than quietly reaching no
# files. One assertion per shape, which is only meaningful because no check is
# an alternation.
missed=()
control() {
    local -n checks=$1 scope=$2
    local entry key label pat files
    for entry in "${checks[@]}"; do
        IFS='|' read -r key label pat <<<"$entry"
        files=$(git grep -lIE -e "$pat" -- "${scope[@]}" || true)
        case $'\n'"$files"$'\n' in
            *$'\n'"$fixture"$'\n'*) ;;
            *) missed+=("$key") ;;
        esac
    done
}
control value_checks value_scope
control option_checks option_scope
ip_files=$(git grep -lIE -e "$ip_assign" -- "${option_scope[@]}" || true)
case $'\n'"$ip_files"$'\n' in
    *$'\n'"$fixture"$'\n'*) ;;
    *) missed+=('initialpassword') ;;
esac

if [ ${#missed[@]} -gt 0 ]; then
    printf 'check-privacy: %s is untracked, or a scan pathspec no longer reaches it; unexercised: %s\n' \
        "$fixture" "${missed[*]}" >&2
    exit 1
fi

# Printed on success too: an exemption is a hole, and a growing count should be
# visible in CI output rather than discoverable only by grep.
ex=$(git grep -cIE -e "#[[:space:]]*${mk}\[" -- . || true)
if [ -n "$ex" ]; then
    printf 'check-privacy: exemptions in force:\n%s\n' "$ex"
else
    printf '  ok  no exemption markers in the tree\n'
fi

[ "$status" -eq 0 ] && printf 'check-privacy: clean; %d shapes, each exercised against %s\n' \
    "$(( ${#value_checks[@]} + ${#option_checks[@]} + 1 ))" "$fixture"
exit "$status"
