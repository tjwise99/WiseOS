default:
    @just --list

[group('checks')]
[doc('Every flake output evaluates to a derivation, without building one')]
check-eval:
    bash scripts/check-eval.sh

[group('checks')]
[doc('Nothing machine-identifying is committed. Run it for the list — it prints what it enforced')]
check-privacy:
    bash scripts/check-privacy.sh

[group('checks')]
[doc('No credential material in the working tree, or anywhere in history')]
check-secrets:
    gitleaks dir . --no-banner --redact
    gitleaks git . --no-banner --redact

[group('checks')]
[doc('Every sops-managed secret file is fully encrypted, not just carrying metadata')]
check-sops:
    bash scripts/check-sops.sh

[group('checks')]
[doc('statix and deadnix are clean against the locked nixpkgs')]
check-lint:
    bash scripts/check-lint.sh

[group('checks')]
[doc('Every check-* recipe is wired into verify')]
check-recipes:
    bash scripts/check-recipes.sh

[doc('Everything CI runs. CI runs this recipe, so the two cannot drift')]
verify: check-recipes check-privacy check-secrets check-sops check-lint check-eval
