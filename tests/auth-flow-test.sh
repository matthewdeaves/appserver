#!/usr/bin/env bash
# shellcheck disable=SC2016  # sandbox bodies use literal $VAR strings on purpose
# auth-flow-test.sh — assertion harness for the operator-role auth helpers
# in scripts/appserver.sh (assume_role, ensure_session_valid_for_role,
# session_valid, get_role_arn, cmd_auth_status, SUBCOMMAND_ROLE map).
#
# Strategy:
#   - Source appserver.sh in a sandboxed shell with a stub `aws` and
#     stub `terraform` on PATH ahead of the real binaries.
#   - Stubs read intent from env vars (e.g. STUB_ASSUME_ROLE_OUTPUT,
#     STUB_ACCOUNT_ID) so each test sets up its own world.
#   - Profiles are written to a temp HOME so we don't touch the
#     operator's real ~/.aws/credentials.
#
# Run:
#   bash tests/auth-flow-test.sh
#
# Exits non-zero if any case fails. Wired into CI by validate.yml.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPSERVER_SH="$REPO_ROOT/scripts/appserver.sh"

PASS=0
FAIL=0
FAILED_CASES=()

# Sandbox setup. Each test gets a fresh HOME and stub PATH.
SANDBOX_ROOT=$(mktemp -d -t appserver-auth-test.XXXXXX)
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

mk_sandbox() {
  local name="$1"
  local sb="$SANDBOX_ROOT/$name"
  mkdir -p "$sb/home/.aws" "$sb/bin"
  echo "$sb"
}

# Build a stub `aws` that reads canned responses from env vars. Args are
# the AWS CLI sub-command line (e.g. "sts assume-role --role-arn ...").
make_stub_aws() {
  local sb="$1"
  cat >"$sb/bin/aws" <<'STUB'
#!/usr/bin/env bash
# Stub `aws` for auth-flow-test.sh. Behaviour driven by env vars:
#   STUB_ACCOUNT_ID         — for `sts get-caller-identity --query Account`
#   STUB_ASSUME_ROLE_OUTPUT — JSON returned by `sts assume-role`
#   STUB_LIST_PROFILES      — newline-separated for `configure list-profiles`
#   STUB_ASSUME_ROLE_FAIL=1 — make `sts assume-role` exit 1
#
# `aws configure set/get` actually edits ~/.aws/credentials in the
# sandbox HOME so we test real profile-file behaviour.

set -uo pipefail

# Find the real aws for `configure get/set/list-profiles` since we
# want real INI parsing — only fake the network calls.
REAL_AWS=""
for p in /usr/local/bin/aws /usr/bin/aws "$HOME/.local/bin/aws"; do
  [ -x "$p" ] && REAL_AWS="$p" && break
done
if [ -z "$REAL_AWS" ]; then
  # Fallback: find one that isn't this stub.
  while read -r p; do
    [ "$p" = "$0" ] && continue
    [ -x "$p" ] || continue
    REAL_AWS="$p"
    break
  done < <(command -v -a aws 2>/dev/null)
fi

# Dispatch.
case "${1:-} ${2:-}" in
  "sts get-caller-identity")
    if [ -n "${STUB_ACCOUNT_ID:-}" ]; then
      # Honour --query Account / --output text used by get_role_arn.
      for arg in "$@"; do
        case "$arg" in
          Account)  echo "$STUB_ACCOUNT_ID"; exit 0 ;;
        esac
      done
      printf '{"Account":"%s","Arn":"arn:aws:iam::%s:user/test","UserId":"AIDA"}\n' \
        "$STUB_ACCOUNT_ID" "$STUB_ACCOUNT_ID"
    fi
    exit 0
    ;;
  "sts assume-role")
    if [ -n "${STUB_ASSUME_ROLE_FAIL:-}" ]; then
      echo "AccessDenied stub failure" >&2
      exit 1
    fi
    if [ -n "${STUB_ASSUME_ROLE_OUTPUT:-}" ]; then
      echo "$STUB_ASSUME_ROLE_OUTPUT"
      exit 0
    fi
    echo "stub: STUB_ASSUME_ROLE_OUTPUT not set" >&2
    exit 1
    ;;
  "configure list-profiles")
    if [ -n "${STUB_LIST_PROFILES:-}" ]; then
      printf '%s\n' "$STUB_LIST_PROFILES"
      exit 0
    fi
    [ -n "$REAL_AWS" ] && exec "$REAL_AWS" "$@"
    exit 0
    ;;
  "configure "*)
    [ -n "$REAL_AWS" ] && exec "$REAL_AWS" "$@"
    exit 1
    ;;
esac
echo "stub: unhandled aws call: $*" >&2
exit 99
STUB
  chmod +x "$sb/bin/aws"
}

# Build a stub `terraform` that just exits 0 — appserver.sh uses it
# only for `output -raw region` which we sidestep via tfvars in the sandbox.
make_stub_terraform() {
  local sb="$1"
  cat >"$sb/bin/terraform" <<'STUB'
#!/usr/bin/env bash
# Minimal stub: never actually invoke real terraform during tests.
exit 1
STUB
  chmod +x "$sb/bin/terraform"
}

# Source appserver.sh in a subshell with the sandbox active. The shell
# function is the test body; it runs with the sandbox HOME and PATH.
# Stops appserver.sh from running its dispatcher by passing no args.
run_in_sandbox() {
  local sb="$1"; shift
  local body="$*"

  # Build a tfvars stub so get_region works (avoids terraform output call).
  mkdir -p "$sb/repo/terraform"
  cat >"$sb/repo/terraform/terraform.tfvars" <<EOF
region = "eu-west-2"
EOF

  HOME="$sb/home" \
  PATH="$sb/bin:$PATH" \
  bash -c '
    set -uo pipefail
    # Dummy SCRIPT_DIR/TERRAFORM_DIR/CONFIG_DIR so `source` does not exit.
    cd "'"$sb"'/repo"
    mkdir -p config
    set -- # no args so the dispatcher case "${1:-}" hits *) help branch
    source "'"$APPSERVER_SH"'" >/dev/null 2>&1 || true
    '"$body"'
  '
}

assert_pass() {
  local label="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[fail rc=$rc] $label")
  fi
}

assert_fail() {
  local label="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[expected nonzero rc] $label")
  fi
}

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[$label] want='$want' got='$got'")
  fi
}

assert_match() {
  local label="$1" pattern="$2" got="$3"
  if echo "$got" | grep -qE "$pattern"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[$label] pattern='$pattern' missed in: $got")
  fi
}

# ============================================================================
# get_role_arn — derives the ARN from STS account ID + role short name
# ============================================================================
SB=$(mk_sandbox role-arn)
make_stub_aws "$SB"
make_stub_terraform "$SB"

got=$(STUB_ACCOUNT_ID=999888777666 \
  run_in_sandbox "$SB" 'get_role_arn readonly')
assert_eq "get_role_arn readonly" \
  "arn:aws:iam::999888777666:role/appserver-readonly-role" "$got"

got=$(STUB_ACCOUNT_ID=999888777666 \
  run_in_sandbox "$SB" 'get_role_arn cookie-ops')
assert_eq "get_role_arn cookie-ops" \
  "arn:aws:iam::999888777666:role/appserver-cookie-ops-role" "$got"

got=$(STUB_ACCOUNT_ID=999888777666 \
  run_in_sandbox "$SB" 'get_role_arn deploy')
assert_eq "get_role_arn deploy" \
  "arn:aws:iam::999888777666:role/appserver-deploy-role" "$got"

# Unknown role short-name should fail.
STUB_ACCOUNT_ID=999888777666 run_in_sandbox "$SB" 'get_role_arn bogus' >/dev/null
assert_fail "get_role_arn rejects unknown role" $?

# ============================================================================
# session_valid — only true when aws_session_expiration is >5 min away
# ============================================================================
SB=$(mk_sandbox session-valid)
make_stub_aws "$SB"
make_stub_terraform "$SB"

# Fresh session: 30 min in the future.
future_30m=$(date -u -d '+30 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$future_30m" --profile appserver-readonly

run_in_sandbox "$SB" 'session_valid appserver-readonly' >/dev/null
assert_pass "session_valid: future 30m valid" $?

# Already expired.
past=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$past" --profile appserver-readonly

run_in_sandbox "$SB" 'session_valid appserver-readonly' >/dev/null
assert_fail "session_valid: expired session rejected" $?

# Within 5-minute buffer.
soon=$(date -u -d '+2 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$soon" --profile appserver-readonly

run_in_sandbox "$SB" 'session_valid appserver-readonly' >/dev/null
assert_fail "session_valid: <5min buffer rejected" $?

# Profile with no expiration recorded.
SB=$(mk_sandbox session-valid-bare)
make_stub_aws "$SB"
make_stub_terraform "$SB"
HOME="$SB/home" aws configure set region eu-west-2 --profile appserver-readonly

run_in_sandbox "$SB" 'session_valid appserver-readonly' >/dev/null
assert_fail "session_valid: profile without expiration rejected" $?

# ============================================================================
# assume_role — writes the right profile shape on success
# ============================================================================
SB=$(mk_sandbox assume-role-success)
make_stub_aws "$SB"
make_stub_terraform "$SB"

future=$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
ASSUME_OUTPUT=$(jq -nc --arg expiry "$future" '{
  Credentials: {
    AccessKeyId: "ASIA1234567890",
    SecretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    SessionToken: "FAKE_SESSION_TOKEN_FOR_TEST",
    Expiration: $expiry
  }
}')

# Pipe in MFA code (6 digits) via `read -rsp`. We export the canned aws
# response and trick the prompt by piping a fake code on stdin.
out=$(STUB_ACCOUNT_ID=111122223333 \
      STUB_ASSUME_ROLE_OUTPUT="$ASSUME_OUTPUT" \
      MFA_SERIAL_NUMBER=arn:aws:iam::111122223333:mfa/appserver-deployer \
      run_in_sandbox "$SB" '
        # Feed the read for the 6-digit code.
        assume_role readonly <<<"123456" 2>&1
        echo "---"
        aws configure get aws_access_key_id --profile appserver-readonly
        aws configure get aws_session_expiration --profile appserver-readonly
      ')
echo "$out" | grep -q "ASIA1234567890"
assert_pass "assume_role: writes access key to profile" $?
echo "$out" | grep -q "$future"
assert_pass "assume_role: writes expiration to profile" $?

# Invalid MFA code (4 digits) must die before calling sts.
STUB_ACCOUNT_ID=111122223333 \
  MFA_SERIAL_NUMBER=arn:aws:iam::111122223333:mfa/appserver-deployer \
  run_in_sandbox "$SB" 'assume_role readonly <<<"1234"' >/dev/null 2>&1
assert_fail "assume_role: rejects 4-digit code" $?

# Missing MFA_SERIAL_NUMBER must fail.
STUB_ACCOUNT_ID=111122223333 \
  run_in_sandbox "$SB" 'assume_role readonly <<<"123456"' >/dev/null 2>&1
assert_fail "assume_role: rejects missing MFA serial" $?

# sts:AssumeRole returning an error must propagate.
STUB_ACCOUNT_ID=111122223333 \
  STUB_ASSUME_ROLE_FAIL=1 \
  MFA_SERIAL_NUMBER=arn:aws:iam::111122223333:mfa/appserver-deployer \
  run_in_sandbox "$SB" 'assume_role readonly <<<"123456"' >/dev/null 2>&1
assert_fail "assume_role: surfaces sts failure" $?

# ============================================================================
# ensure_session_valid_for_role — phase 5 cutover: legacy fallback REMOVED.
# Without MFA_SERIAL_NUMBER, the helper must die regardless of whether a
# legacy `appserver` profile is present in ~/.aws/credentials.
# ============================================================================
SB=$(mk_sandbox legacy-removed)
make_stub_aws "$SB"
make_stub_terraform "$SB"
HOME="$SB/home" aws configure set aws_access_key_id LEGACY     --profile appserver
HOME="$SB/home" aws configure set aws_secret_access_key SECRET  --profile appserver
HOME="$SB/home" aws configure set region eu-west-2              --profile appserver

# Even with the legacy profile present, no MFA = die. (Phase 5: no fallback.)
STUB_LIST_PROFILES="appserver" \
  run_in_sandbox "$SB" '
    unset MFA_SERIAL_NUMBER
    ensure_session_valid_for_role readonly
  ' >/dev/null 2>&1
assert_fail "ensure_session_valid_for_role: no MFA dies even with legacy profile present" $?

# Without MFA AND without legacy profile -> die.
SB=$(mk_sandbox no-fallback)
make_stub_aws "$SB"
make_stub_terraform "$SB"
STUB_LIST_PROFILES="" run_in_sandbox "$SB" '
    unset MFA_SERIAL_NUMBER
    ensure_session_valid_for_role readonly
  ' >/dev/null 2>&1
assert_fail "ensure_session_valid_for_role: no legacy + no MFA exits non-zero" $?

# With a fresh cached session, ensure_session_valid_for_role uses it
# without prompting.
SB=$(mk_sandbox cached-session)
make_stub_aws "$SB"
make_stub_terraform "$SB"
future=$(date -u -d '+50 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_access_key_id ASIACACHED                --profile appserver-readonly
HOME="$SB/home" aws configure set aws_secret_access_key wJSECRET              --profile appserver-readonly
HOME="$SB/home" aws configure set aws_session_token TOKEN                     --profile appserver-readonly
HOME="$SB/home" aws configure set aws_session_expiration "$future"            --profile appserver-readonly
HOME="$SB/home" aws configure set region eu-west-2                             --profile appserver-readonly

out=$(MFA_SERIAL_NUMBER=arn:aws:iam::1:mfa/test \
      run_in_sandbox "$SB" '
        ensure_session_valid_for_role readonly 2>&1
        echo "AWS_PROFILE=$AWS_PROFILE"
      ')
echo "$out" | grep -q "AWS_PROFILE=appserver-readonly"
assert_pass "ensure_session_valid_for_role: reuses cached fresh session" $?
# Should NOT have called assume_role / prompted for MFA — verify by
# checking the cached profile is still ASIACACHED.
got_key=$(HOME="$SB/home" aws configure get aws_access_key_id --profile appserver-readonly)
assert_eq "ensure_session_valid_for_role: cached profile untouched" "ASIACACHED" "$got_key"

# APPSERVER_AUTH_DISABLED=1 short-circuits everything.
out=$(APPSERVER_AUTH_DISABLED=1 \
      run_in_sandbox "$SB" 'ensure_session_valid_for_role readonly 2>&1; echo "rc=$?"')
echo "$out" | grep -q "rc=0"
assert_pass "ensure_session_valid_for_role: AUTH_DISABLED bypasses entirely" $?

# ============================================================================
# cmd_auth_status — shows a line per role with state
# ============================================================================
SB=$(mk_sandbox auth-status)
make_stub_aws "$SB"
make_stub_terraform "$SB"
future=$(date -u -d '+45 minutes' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$future" --profile appserver-readonly
HOME="$SB/home" aws configure set region eu-west-2                  --profile appserver-readonly
past=$(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%S+0000')
HOME="$SB/home" aws configure set aws_session_expiration "$past"    --profile appserver-cookie-ops
HOME="$SB/home" aws configure set region eu-west-2                  --profile appserver-cookie-ops

out=$(run_in_sandbox "$SB" 'cmd_auth_status 2>&1')
assert_match "auth status: readonly active"   "readonly:.*active" "$out"
assert_match "auth status: cookie-ops expired" "cookie-ops:.*expired" "$out"
assert_match "auth status: deploy not authed" "deploy:.*not authenticated" "$out"

# ============================================================================
# SUBCOMMAND_ROLE coverage — no AWS-touching subcommand should be missing
# ============================================================================
SB=$(mk_sandbox map-coverage)
make_stub_aws "$SB"
make_stub_terraform "$SB"

# Pull the SUBCOMMAND_ROLE map keys from a sourced shell.
keys=$(run_in_sandbox "$SB" 'printf "%s\n" "${!SUBCOMMAND_ROLE[@]}" | sort')

# Required keys for current AWS-touching subcommands.
# init + destroy are NOT in this map by design — they require admin
# (not deploy-role) to manage IAM bootstrap and tear down the boundary
# policies that bound the operator roles. They drive their own
# admin_mfa_session via the admin profile.
required=(
  status health users logs spend
  app_list app_deploy app_init app_remove app_restart app_env
  config_push
  threats_default threats_block threats_unblock threats_blocked
  threats_allow threats_unallow threats_allowed threats_list threats_report
  setup_unlock
  deploy start stop ssh
)
# Explicit "must NOT be in map" assertions — these are admin-driven.
forbidden=(destroy)

for key in "${required[@]}"; do
  if echo "$keys" | grep -qx "$key"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[SUBCOMMAND_ROLE missing key] $key")
  fi
done

for key in "${forbidden[@]}"; do
  if echo "$keys" | grep -qx "$key"; then
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("[SUBCOMMAND_ROLE has forbidden key] $key (admin-driven; should not be in role map)")
  else
    PASS=$((PASS + 1))
  fi
done

# ============================================================================
# Result
# ============================================================================
echo
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for f in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
