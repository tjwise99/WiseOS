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
# control — sops-nix, in hosts/wise-laptop/secrets.yaml, decrypted at
# activation and never written to the store. What backs this backstop is that a
# secret has a correct home to be in; this scan still catches one typed in
# plaintext straight into a committed file, which sops cannot prevent.
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
  'mac-colon|MAC address, colon-separated|([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
  'mac-dash|MAC address, dash-separated|([0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}'
  'ipv4-10|private IPv4, RFC1918 ten-dot range|(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-192|private IPv4, RFC1918 192.168 range|(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-172|private IPv4, RFC1918 172.16-31 range|(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-cgnat|CGNAT 100.64-127 range — a tailnet address names a specific machine|(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv4-linklocal|link-local 169.254 range|(^|[^0-9.])169\.254\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ipv6-ula|IPv6 unique local address, fd00::/8|(^|[^0-9a-fA-F:])fd[0-9a-fA-F]{2}:[0-9a-fA-F]{0,4}:[0-9a-fA-F:]+'
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

# sops-managed secret files must actually be encrypted. This is the one
# positive assertion in a file of denylists, and it exists because the denylist
# cannot cover this: sops.validateSopsFiles does not reject a plaintext file at
# eval, and a hash written in YAML `key: value` form is matched by none of the
# option checks above, which all key on `=`. So a secret saved in the clear —
# whether stripped of its sops metadata or with plaintext values under intact
# metadata — would pass every other check and `nix eval` besides.
#
# A file is treated as a secret if it is named `*secrets.{yaml,yml,json}` (the
# convention) OR already carries a `sops:` metadata block; either way it must be
# encrypted. `.sops.yaml` is the recipient config, not a secret: it is neither
# named `secrets.*` nor carries that block. Markdown is excluded so a doc that
# shows `sops:` in an example is not mistaken for a secret.
secret_files=$(
    {
        git ls-files -- '*secrets.yaml' '*secrets.yml' '*secrets.json'
        git grep -lI -e '^sops:' -- . ':(exclude)*.md' 2>/dev/null || true
    } | sort -u
)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    meta=$(git grep -lI -e '^sops:' -- "$f" || true)
    enc=$(git grep -lI -e 'ENC\[' -- "$f" || true)
    plain=$(git grep -nIE -e '\$(1|2[abxy]|5|6|7|y|gy)\$' -- "$f" 2>/dev/null \
        | { grep -vE 'ENC\[' || true; })
    if [ -z "$meta" ] || [ -z "$enc" ]; then
        printf 'check-privacy: %s is a secret file but not sops-encrypted (sops: metadata or ENC[] value absent)\n' "$f" >&2
        status=1
    elif [ -n "$plain" ]; then
        printf 'check-privacy: %s has a plaintext hash outside an ENC[] value:\n%s\n' "$f" "$plain" >&2
        status=1
    else
        printf '  ok  %s is sops-encrypted\n' "$f"
    fi
done <<EOF
$secret_files
EOF

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
