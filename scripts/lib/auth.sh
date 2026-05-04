# shellcheck shell=bash
# scripts/lib/auth.sh — operator-role auth (MFA + sts:AssumeRole) helpers
# and the user-facing `auth` subcommand.
# Sourced by appserver.sh. Relies on die(), get_region() from the parent
# shell, and the AWS CLI + jq + a long-lived `appserver` profile.
#
# The CLI assumes one of three IAM roles per subcommand
# (readonly / cookie-ops / deploy), each gated by MFA + a 1-hour STS
# session. See specs/003-iam-mfa-scoping/spec.md.
#
# Phase 5 cutover: long-lived `appserver` profile fallback removed.
# All AWS-touching subcommands now require either an active operator-role
# session (assume_role -> appserver-<role> profile) or an explicit
# APPSERVER_AUTH_DISABLED=1 escape hatch (tests / local dev).

APPSERVER_AUTH_DISABLED="${APPSERVER_AUTH_DISABLED:-}"  # tests can set =1 to bypass

get_mfa_serial() {
  if [[ -n "${MFA_SERIAL_NUMBER:-}" ]]; then
    echo "$MFA_SERIAL_NUMBER"
    return 0
  fi
  return 1
}

# Construct the operator role ARN for a short role name. Pulls account ID
# from sts:GetCallerIdentity (whatever profile is currently active).
get_role_arn() {
  local role="$1"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || return 1
  case "$role" in
    readonly)   echo "arn:aws:iam::${account_id}:role/appserver-readonly-role" ;;
    cookie-ops) echo "arn:aws:iam::${account_id}:role/appserver-cookie-ops-role" ;;
    deploy)     echo "arn:aws:iam::${account_id}:role/appserver-deploy-role" ;;
    *)          return 1 ;;
  esac
}

# Check whether the named profile has a non-expired STS session
# (more than 5 minutes remaining on aws_session_expiration).
session_valid() {
  local profile="$1"
  local expires_at
  expires_at=$(aws configure get aws_session_expiration --profile "$profile" 2>/dev/null) || return 1
  [[ -n "$expires_at" ]] || return 1

  local now expiry_epoch
  now=$(date -u +%s)
  expiry_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || return 1
  local remaining=$((expiry_epoch - now))
  [[ $remaining -gt 300 ]]
}

# Prompt for a TOTP code, call sts:AssumeRole, write the resulting
# session to ~/.aws/credentials under profile appserver-<role>, and
# export AWS_PROFILE.
assume_role() {
  local role="$1"
  local role_arn mfa_serial
  role_arn=$(get_role_arn "$role") \
    || die "Could not derive role ARN for '$role'. Check AWS credentials work first."
  mfa_serial=$(get_mfa_serial) \
    || die "MFA_SERIAL_NUMBER not set. Add it to terraform local-env file (see HANDOFF.md phase 2)."

  local session_name
  session_name="${role//-/_}-$(date +%s)"
  local code
  echo "Enter MFA code for '$role' role:" >&2
  read -rsp "  " code
  echo >&2
  [[ "$code" =~ ^[0-9]{6}$ ]] || die "Invalid MFA code (expected 6 digits)"

  local creds
  # Use the default credential chain (long-lived deployer key) to call
  # sts:AssumeRole; do NOT chain off an already-assumed session.
  creds=$(AWS_PROFILE=appserver aws sts assume-role \
    --role-arn "$role_arn" \
    --role-session-name "$session_name" \
    --serial-number "$mfa_serial" \
    --token-code "$code" \
    --duration-seconds 3600 \
    --output json 2>&1) || die "sts:AssumeRole failed: $creds"

  local profile="appserver-$role"
  local region key secret token expiry
  region="$(get_region)"
  key=$(echo "$creds"   | jq -r '.Credentials.AccessKeyId')
  secret=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
  token=$(echo "$creds"  | jq -r '.Credentials.SessionToken')
  expiry=$(echo "$creds" | jq -r '.Credentials.Expiration')
  [[ -n "$key" && -n "$secret" && -n "$token" && -n "$expiry" ]] \
    || die "Failed to parse sts:AssumeRole response"

  aws configure set aws_access_key_id      "$key"    --profile "$profile"
  aws configure set aws_secret_access_key  "$secret" --profile "$profile"
  aws configure set aws_session_token      "$token"  --profile "$profile"
  aws configure set aws_session_expiration "$expiry" --profile "$profile"
  aws configure set region                 "$region" --profile "$profile"
  aws configure set output                 json      --profile "$profile"

  export AWS_PROFILE="$profile"
  echo "Assumed $role role (expires $expiry)" >&2
}

# Mints a 1-hour MFA-derived STS session for the appserver-admin user (the
# shared admin shared with Rockport, used by `appserver.sh init`). Reads
# APPSERVER_ADMIN_MFA_SERIAL from the local-env file. Writes creds under the
# appserver-admin-mfa profile and exports AWS_PROFILE. Skipped if
# APPSERVER_AUTH_DISABLED=1 (true bootstrap on a fresh account where the
# AppserverAdmin policy isn't deployed yet).
#
# Why: AppserverAdmin's DenyAllWithoutMFA statement (004) explicit-denies
# every action outside a tiny safe-list when aws:MultiFactorAuthPresent is
# false. A leaked admin access key is therefore useless without the second
# factor.
admin_mfa_session() {
  [[ -n "$APPSERVER_AUTH_DISABLED" ]] && return 0

  local profile="appserver-admin-mfa"

  if [[ -z "${APPSERVER_ADMIN_MFA_SERIAL:-}" ]]; then
    die "APPSERVER_ADMIN_MFA_SERIAL not set. Enrol MFA on the shared admin user (rockport-admin) and add the device ARN to the local-env file (see terraform/.env.example). Or set APPSERVER_AUTH_DISABLED=1 only when bootstrapping a fresh account where the AppserverAdmin policy isn't deployed yet."
  fi

  if session_valid "$profile"; then
    export AWS_PROFILE="$profile"
    return 0
  fi

  local code=""
  while [[ ! "$code" =~ ^[0-9]{6}$ ]]; do
    read -rsp "TOTP code for appserver-admin: " code
    echo
    [[ ! "$code" =~ ^[0-9]{6}$ ]] && echo "  (need a 6-digit code; try again)" >&2
  done

  local creds
  creds=$(env -u AWS_PROFILE aws sts get-session-token \
    --serial-number "$APPSERVER_ADMIN_MFA_SERIAL" \
    --token-code "$code" \
    --duration-seconds 3600 \
    --output json) || die "sts:GetSessionToken failed for appserver-admin"

  local key secret token expiry region
  region="$(get_region)"
  key=$(echo "$creds"   | jq -r '.Credentials.AccessKeyId')
  secret=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
  token=$(echo "$creds"  | jq -r '.Credentials.SessionToken')
  expiry=$(echo "$creds" | jq -r '.Credentials.Expiration')
  [[ -n "$key" && -n "$secret" && -n "$token" && -n "$expiry" ]] \
    || die "Failed to parse sts:GetSessionToken response"

  aws configure set aws_access_key_id      "$key"    --profile "$profile"
  aws configure set aws_secret_access_key  "$secret" --profile "$profile"
  aws configure set aws_session_token      "$token"  --profile "$profile"
  aws configure set aws_session_expiration "$expiry" --profile "$profile"
  aws configure set region                 "$region" --profile "$profile"
  aws configure set output                 json      --profile "$profile"

  export AWS_PROFILE="$profile"
  echo "Assumed appserver-admin (MFA) until $expiry" >&2
}

# Ensure a valid session exists for the requested role, assuming if not.
# Phase 5: legacy long-lived `appserver` profile fallback removed.
ensure_session_valid_for_role() {
  local role="$1"
  [[ -n "$APPSERVER_AUTH_DISABLED" ]] && return 0  # tests / explicit opt-out

  if ! get_mfa_serial >/dev/null 2>&1; then
    die "MFA_SERIAL_NUMBER not set. Add it to the terraform local-env file and run './scripts/appserver.sh auth'."
  fi

  local profile="appserver-$role"
  if session_valid "$profile"; then
    export AWS_PROFILE="$profile"
    return 0
  fi
  assume_role "$role"
}

# --- Auth subcommand (user-facing) ---

cmd_auth() {
  local role=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        role="${2:-}"; shift 2 || die "Missing role after --role"
        ;;
      status)
        cmd_auth_status
        return $?
        ;;
      --help|-h)
        echo "Usage: appserver auth [--role <readonly|cookie-ops|deploy>]"
        echo "       appserver auth status"
        echo
        echo "Authenticate via MFA + sts:AssumeRole and write a 1-hour STS"
        echo "session to a local AWS profile. Subsequent CLI subcommands"
        echo "automatically pick the right role per their scope."
        return 0
        ;;
      *)
        die "Unknown argument: $1 (try 'appserver auth --help')"
        ;;
    esac
  done

  if [[ -z "$role" ]]; then
    echo "Which role do you want to assume?"
    echo "  1) readonly   — diagnostic / triage (default)"
    echo "  2) cookie-ops — cookie app management"
    echo "  3) deploy     — full infrastructure changes"
    read -rp "Role [1]: " choice
    # shellcheck disable=SC2209  # role names — not the `readonly` builtin
    case "${choice:-1}" in
      1|readonly)   role=readonly ;;
      2|cookie-ops) role=cookie-ops ;;
      3|deploy)     role=deploy ;;
      *)            die "Unknown role choice: $choice" ;;
    esac
  fi

  case "$role" in
    readonly|cookie-ops|deploy) ;;
    *) die "Invalid role: $role (expected: readonly, cookie-ops, deploy)" ;;
  esac

  assume_role "$role"
}

cmd_auth_status() {
  echo "Operator role sessions:"
  for role in readonly cookie-ops deploy; do
    local profile="appserver-$role"
    if aws configure list-profiles 2>/dev/null | grep -q "^${profile}\$"; then
      local expires_at
      expires_at=$(aws configure get aws_session_expiration --profile "$profile" 2>/dev/null) || expires_at=""
      if [[ -n "$expires_at" ]]; then
        local now expiry_epoch remaining_s
        now=$(date -u +%s)
        expiry_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || expiry_epoch=$now
        remaining_s=$((expiry_epoch - now))
        if [[ $remaining_s -gt 0 ]]; then
          local remaining_m=$((remaining_s / 60))
          echo "  $role:  active (${remaining_m}m remaining, expires $expires_at)"
        else
          echo "  $role:  expired ($expires_at)"
        fi
      else
        echo "  $role:  configured but no STS expiry recorded"
      fi
    else
      echo "  $role:  not authenticated"
    fi
  done
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    echo
    echo "Active profile: $AWS_PROFILE"
  fi
}
