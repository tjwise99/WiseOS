#!/usr/bin/env bash
# Every sops-managed secret file must be FULLY encrypted: every value outside
# the `sops:` metadata block must be an ENC[...] ciphertext.
#
# This is a structural assertion, not a substring one, because both obvious
# shortcuts are vacuous. `git grep ENC\[` is satisfied by the `sops.mac: ENC[…]`
# that sits in the metadata of *every* sops file, encrypted data or not. And
# `sops filestatus` reports {"encrypted":true} on a file whose metadata is
# intact but whose data values were hand-edited back to plaintext — the single
# most likely way a leak happens here, someone adding a second secret without
# the `sops` round-trip. Both were verified to pass a plaintext wifi_psk. So the
# check parses the file: it stops at the metadata block and requires each data
# scalar to begin with ENC[, reading the value rather than filtering the line
# (a trailing `# ENC[…]` comment does not launder a plaintext value).
#
# Denylist-shaped leaks — a loose hash, a UUID — are check-privacy's job. This
# one owns the opposite question: are the files that are *supposed* to be
# encrypted actually, completely, encrypted.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

fixture='tests/sops-plaintext-fixture.yaml'

# Returns 0 if every data value is ENC[...], 1 otherwise, printing offenders.
# Everything from the first `^sops:` line to EOF is metadata and is skipped;
# sops always emits it last. A `key:` with no value is a container and passes;
# a `- ENC[…]` list item passes; anything with a value not starting ENC[ fails.
fully_encrypted() {
    awk '
        /^sops:/ { insops = 1 }
        insops   { next }
        /^[[:space:]]*#/  { next }
        /^[[:space:]]*$/  { next }
        {
            if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                val = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", val)
                if (val != "" && val !~ /^ENC\[/) { printf "  line %d: %s\n", NR, $0; bad = 1 }
                next
            }
            if ($0 ~ /:/) {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
                if (val != "" && val !~ /^ENC\[/) { printf "  line %d: %s\n", NR, $0; bad = 1 }
            }
        }
        END { exit bad + 0 }
    ' "$1"
}

status=0

# Positive control: a file with valid-looking metadata and a plaintext value.
# If the parser calls it encrypted, the parser is broken — fail loudly rather
# than pass every real file by the same broken logic.
if [ ! -f "$fixture" ]; then
    echo "check-sops: positive-control fixture $fixture is missing" >&2
    exit 1
fi
if fully_encrypted "$fixture" >/dev/null; then
    echo "check-sops: positive control did not fire — $fixture reads as encrypted, so the parser is broken" >&2
    exit 1
fi

# Discover secret files three independent ways, so no single rename or new name
# can make the check silently cover nothing (the failure mode a filename-only
# convention has). Union, minus the fixture and markdown:
#   1. referenced as a sops file in the Nix config — the strongest signal, since
#      a file the config decrypts must be named there, resolved relative to the
#      referencing module's directory;
#   2. named by the *secrets.{yaml,yml,json} convention;
#   3. already carrying a `sops:` metadata block.
referenced=$(
    git grep -nIE -e '(defaultSopsFile|sopsFile)[[:space:]]*=[[:space:]]*\./' -- '*.nix' 2>/dev/null \
    | while IFS=: read -r file _ rest; do
        rel=$(printf '%s' "$rest" | grep -oE '\./[^ ;"]+' | head -1)
        [ -n "$rel" ] || continue
        printf '%s/%s\n' "$(dirname "$file")" "${rel#./}"
    done
)
secret_files=$(
    {
        printf '%s\n' "$referenced"
        git ls-files -- '*secrets.yaml' '*secrets.yml' '*secrets.json'
        git grep -lI -e '^sops:' -- . ':(exclude)*.md' ":(exclude)${fixture}" 2>/dev/null || true
    } | grep -v '^$' | sort -u
)

# A Nix reference to a sops file that is not tracked is a dangling secret path —
# the config would fail to build, but say so here in the terms that matter.
while IFS= read -r r; do
    [ -n "$r" ] || continue
    git ls-files --error-unmatch -- "$r" >/dev/null 2>&1 || {
        echo "check-sops: $r is referenced as a sops file in the Nix config but is not tracked" >&2
        status=1
    }
done <<EOF
$referenced
EOF

# Floor: the config references at least one sops file, so discovering zero to
# check is a broken scan, not a clean tree.
if [ -n "$referenced" ] && [ -z "$secret_files" ]; then
    echo 'check-sops: the Nix config references a sops file but none were discovered to check' >&2
    exit 1
fi

checked=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    checked=$((checked + 1))
    if plain=$(fully_encrypted "$f"); then
        printf '  ok  %s is fully encrypted\n' "$f"
    else
        printf 'check-sops: %s has plaintext value(s) outside the sops: metadata block:\n%s\n' "$f" "$plain" >&2
        status=1
    fi
done <<EOF
$secret_files
EOF

[ "$status" -eq 0 ] && printf 'check-sops: %d secret file(s) fully encrypted; parser proven against %s\n' \
    "$checked" "$fixture"
exit "$status"
