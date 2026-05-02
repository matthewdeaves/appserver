#!/usr/bin/env bash
# install-git-hooks.sh — drop the per-clone pre-commit hook.
#
# The hook runs gitleaks against staged changes before each commit,
# blocking accidental credential commits. Run once after cloning:
#
#   ./scripts/install-git-hooks.sh
#
# If you'd rather use the `pre-commit` framework, install it
# (`pipx install pre-commit && pre-commit install`) — the same checks
# (plus shellcheck and the basic file checks) are wired in
# .pre-commit-config.yaml.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
hook_path="$repo_root/.git/hooks/pre-commit"

cat >"$hook_path" <<'HOOK'
#!/usr/bin/env bash
# Auto-installed by scripts/install-git-hooks.sh
# Edits to this file are not version-controlled — re-run the installer
# after pulling changes to scripts/install-git-hooks.sh to refresh.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)

# Resolve gitleaks. Many users have it under ~/.local/bin which isn't
# always in PATH for non-interactive shells (where git invokes hooks).
gitleaks_bin=""
for candidate in gitleaks "$HOME/.local/bin/gitleaks" "/usr/local/bin/gitleaks" "/opt/homebrew/bin/gitleaks"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    gitleaks_bin="$candidate"
    break
  fi
done

if [ -z "$gitleaks_bin" ]; then
  echo "pre-commit: gitleaks not found in PATH or common locations." >&2
  echo "  Install: https://github.com/gitleaks/gitleaks#installing" >&2
  echo "  Or skip this hook for one commit: git commit --no-verify ..." >&2
  exit 1
fi

# `gitleaks protect --staged` only scans the staged diff — fast.
"$gitleaks_bin" protect --staged --no-banner --redact \
  --config="$repo_root/.gitleaks.toml"
HOOK

chmod +x "$hook_path"
echo "Installed: $hook_path"
echo "Hook runs 'gitleaks protect --staged' on every commit."
echo "Skip for one commit: git commit --no-verify"
