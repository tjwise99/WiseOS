default:
    @just --list

[group('checks')]
[doc('Every flake output evaluates to a derivation, without building one')]
check-eval:
    bash scripts/check-eval.sh

[group('checks')]
[doc('No disk UUID, MAC, SSID, wireless key, password hash or private address is committed')]
check-privacy:
    bash scripts/check-privacy.sh

[group('checks')]
[doc('No credential material in the working tree')]
check-secrets:
    gitleaks dir . --no-banner --redact

[group('checks')]
[doc('statix and deadnix are clean against the locked nixpkgs')]
check-lint:
    bash scripts/check-lint.sh

[doc('Everything CI runs. CI runs this recipe, so the two cannot drift')]
verify: check-privacy check-secrets check-lint check-eval
