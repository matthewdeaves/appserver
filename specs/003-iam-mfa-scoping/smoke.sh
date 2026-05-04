#!/usr/bin/env bash
# smoke.sh — operator-driven verification of the v0.2.0 IAM rollout.
#
# Walks through Phases A (auth flow), B (deploy-role no-op),
# D (Finding-2 deny check), and optional C (full destroy + redeploy).
# Each phase prompts before continuing. Each `appserver.sh` call may
# prompt for an MFA TOTP code interactively — type it as the
# authenticator displays it.
#
# Run from the repo root:
#   ./specs/003-iam-mfa-scoping/smoke.sh
#
# Safe to abort at any prompt with Ctrl-C.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to repo root" >&2; exit 1; }

# Colour helpers — only if stdout is a TTY.
if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_DIM="" C_RESET=""
fi

announce() {
  echo
  echo "${C_BOLD}══════════════════════════════════════════════════════════════════${C_RESET}"
  echo "${C_BOLD}  $*${C_RESET}"
  echo "${C_BOLD}══════════════════════════════════════════════════════════════════${C_RESET}"
}

step() {
  echo
  echo "${C_BOLD}→ $*${C_RESET}"
}

note() {
  echo "${C_DIM}  $*${C_RESET}"
}

run() {
  echo "${C_DIM}  \$ $*${C_RESET}"
  "$@"
}

confirm() {
  # confirm "Question?" [default y|n]
  local prompt="$1" default="${2:-y}" resp
  if [[ "$default" == "y" ]]; then
    read -rp "  $prompt [Y/n]: " resp
    resp="${resp:-y}"
  else
    read -rp "  $prompt [y/N]: " resp
    resp="${resp:-n}"
  fi
  [[ "$resp" =~ ^[Yy]$ ]]
}

require_clean_shell() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    echo "${C_YELLOW}WARNING: AWS_PROFILE='$AWS_PROFILE' is set. Unsetting for clean test.${C_RESET}"
    unset AWS_PROFILE
  fi
  if [[ ! -f terraform/.env ]]; then
    echo "${C_RED}ERROR: terraform/.env missing. Run setup first.${C_RESET}" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source terraform/.env
  if [[ -z "${MFA_SERIAL_NUMBER:-}" ]]; then
    echo "${C_RED}ERROR: MFA_SERIAL_NUMBER not set in terraform/.env.${C_RESET}" >&2
    echo "  Enrol an MFA device on appserver-deployer first; see HANDOFF.md." >&2
    exit 1
  fi
  echo "${C_GREEN}✓ Clean shell, MFA configured.${C_RESET}"
}

# ============================================================================
# Phase A — Auth flow + cookie-ops smoke
# ============================================================================
phase_a() {
  announce "PHASE A — Auth flow + cookie-ops smoke"
  note "Validates: MFA prompts at the right boundaries, session caching,"
  note "the post-Finding-1 role mapping (status/logs use cookie-ops, not readonly)."

  step "Assume readonly role (TOTP prompt)"
  run ./scripts/appserver.sh auth --role readonly

  step "Show all session expiries"
  run ./scripts/appserver.sh auth status

  step "Run a cookie-ops command (status) — TOTP prompt #2"
  note "status uses cookie-ops because it sends shell to the instance via SSM."
  run ./scripts/appserver.sh status

  step "Run another cookie-ops command (logs) — should reuse cached session"
  run ./scripts/appserver.sh logs cookie 2>&1 | tail -10

  step "Run a readonly-only command (spend) — should reuse cached readonly"
  run ./scripts/appserver.sh spend 2>&1 | head -20 || true

  step "Final auth status"
  run ./scripts/appserver.sh auth status

  echo
  echo "${C_GREEN}✓ Phase A complete.${C_RESET} Two MFA prompts (readonly + cookie-ops),"
  echo "  no others. Subsequent calls within each role reused the cached session."
}

# ============================================================================
# Phase B — Deploy-role no-op apply
# ============================================================================
phase_b() {
  announce "PHASE B — Deploy-role no-op apply"
  note "Validates: deploy-role MFA + permissions, terraform sees state in-sync,"
  note "PIPESTATUS exit-code propagation works (any error fails loud)."

  step "Run terraform deploy via deploy role (TOTP prompt #3)"
  note "Expect: 'Plan: 0 to add, 0 to change, 0 to destroy' + 'Apply complete'"
  run ./scripts/appserver.sh deploy

  step "Confirm all 3 sessions active"
  run ./scripts/appserver.sh auth status

  echo
  echo "${C_GREEN}✓ Phase B complete.${C_RESET} Three MFA prompts total, deploy is a no-op."
}

# ============================================================================
# Phase D — Verify Finding 2 deny works
# ============================================================================
phase_d() {
  announce "PHASE D — Verify DenyOperatorPolicyMutation deny works"
  note "While holding a deploy-role STS session, try the escalation that"
  note "Finding 2's fix was meant to block. Should fail with explicit deny."

  local out rc
  step "Attempt to rewrite the deploy boundary (should fail)"
  set +e
  out=$(aws iam create-policy-version \
    --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/appserver-operator-deploy-boundary" \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}' \
    --set-as-default 2>&1)
  rc=$?
  set -e

  if [[ $rc -ne 0 ]] && echo "$out" | grep -q "explicit deny"; then
    echo "${C_GREEN}✓ Phase D complete.${C_RESET} Deny fired as expected:"
    echo "${C_DIM}  $(echo "$out" | grep -oE 'AccessDenied[^,]*' | head -1)${C_RESET}"
  else
    echo "${C_RED}✗ Phase D FAILED.${C_RESET}"
    echo "  Expected explicit deny, got rc=$rc:"
    echo "$out"
    return 1
  fi
}

# ============================================================================
# Phase C — Full destroy + redeploy (DESTRUCTIVE)
# ============================================================================
phase_c() {
  announce "PHASE C — Full destroy + redeploy ⚠️  DESTRUCTIVE"
  echo "${C_RED}WARNING:${C_RESET} this will:"
  echo "  - terminate the EC2 instance (Cookie's PostgreSQL data goes with it)"
  echo "  - delete the artifacts S3 bucket"
  echo "  - delete the Cloudflare Tunnel + DNS records + Access app"
  echo
  echo "  ${C_BOLD}Cookie's data will be lost${C_RESET} unless you back it up first."
  echo "  The DLM policy snapshots EBS daily at 03:00 UTC (7-day retention)"
  echo "  but restoring is manual."
  echo
  if ! confirm "Proceed with destroy + redeploy?" n; then
    echo "  Skipped Phase C. Done."
    return 0
  fi

  step "Optionally back up Cookie's PostgreSQL first"
  if confirm "Take a pg_dump backup to /tmp on the instance now?" y; then
    note "Dumping cookie DB to /tmp/cookie-backup.sql on the instance..."
    run ./scripts/appserver.sh ssh <<'EOF'
docker exec cookie-db pg_dump -U cookie cookie > /tmp/cookie-backup.sql && wc -c /tmp/cookie-backup.sql
exit
EOF
    note "The dump is on the instance's /tmp. It will be lost when the instance"
    note "terminates. To preserve it across the destroy, copy it to S3 manually:"
    note "  ssh in, then: aws s3 cp /tmp/cookie-backup.sql s3://<artifacts-bucket>/cookie-backup.sql"
    note "(Instance role currently has only s3:GetObject on artifacts — you may"
    note "need to add s3:PutObject temporarily, or use ssm get-command-invocation"
    note "to retrieve via stdout in chunks. For now, accepting data loss.)"
    if ! confirm "Continue with destroy (data WILL be lost)?" n; then
      return 0
    fi
  fi

  step "Run terraform destroy (TOTP prompt expected)"
  echo "  When asked 'Type destroy to confirm:' — type ${C_BOLD}destroy${C_RESET}"
  echo "  When asked 'Also remove bootstrap resources?' — answer ${C_BOLD}N${C_RESET}"
  echo "  (otherwise it wipes the IAM + state bucket and you'll need full re-bootstrap)"
  run ./scripts/appserver.sh destroy

  step "Redeploy infrastructure"
  note "Expect: ~30 resources to add, takes ~2 min"
  run ./scripts/appserver.sh deploy

  step "Re-init Cookie (generates fresh secrets)"
  run ./scripts/appserver.sh app init cookie

  step "Deploy Cookie containers"
  run ./scripts/appserver.sh app deploy cookie

  echo
  echo "${C_GREEN}✓ Phase C complete.${C_RESET} Full lifecycle driven by deploy-role STS sessions only."
  echo "  Visit https://cookie.matthewdeaves.com to register a new passkey."
  echo "  (Old passkeys are gone with the database; restore from snapshot if needed.)"
}

# ============================================================================
# Main flow
# ============================================================================
require_clean_shell

phase_a
echo
confirm "Continue to Phase B (deploy-role no-op)?" y || exit 0
phase_b
echo
confirm "Continue to Phase D (Finding-2 deny check)?" y || exit 0
phase_d
echo
confirm "Continue to Phase C (DESTRUCTIVE — full destroy + redeploy)?" n || {
  echo
  echo "${C_GREEN}═══════════════════════════════════════════════════════════════════${C_RESET}"
  echo "${C_GREEN}  Phases A, B, D complete. Skipped destructive Phase C.${C_RESET}"
  echo "${C_GREEN}═══════════════════════════════════════════════════════════════════${C_RESET}"
  exit 0
}
phase_c

echo
echo "${C_GREEN}═══════════════════════════════════════════════════════════════════${C_RESET}"
echo "${C_GREEN}  All phases complete.${C_RESET}"
echo "${C_GREEN}═══════════════════════════════════════════════════════════════════${C_RESET}"
