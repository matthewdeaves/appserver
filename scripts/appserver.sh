#!/bin/bash

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)" || { echo "ERROR: terraform/ directory not found" >&2; exit 1; }
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "ERROR: config/ directory not found" >&2; exit 1; }
ENV_FILE="$TERRAFORM_DIR/.env"
CACHED_REGION=""
CACHED_INSTANCE_ID=""

# Phase 5: no auto-export of the legacy `appserver` profile. AWS_PROFILE
# is set per-subcommand by ensure_session_valid_for_role -> appserver-<role>.
# Operators who still have a long-lived `appserver` profile in
# ~/.aws/credentials can either rotate to the role flow (recommended) or
# pass AWS_PROFILE=appserver explicitly when they need it.

# --- Helper functions ---

check_dependencies() {
  for cmd in aws terraform jq; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found. Install it first." >&2
      exit 1
    fi
  done
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

get_region() {
  if [[ -n "$CACHED_REGION" ]]; then
    echo "$CACHED_REGION"
    return
  fi
  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    local r
    r=$(sed -n 's/^region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) && [[ -n "$r" ]] && {
      CACHED_REGION="$r"
      echo "$r"
      return
    }
  fi
  local r
  r=$(cd "$TERRAFORM_DIR" && terraform output -raw region 2>/dev/null) && {
    CACHED_REGION="$r"
    echo "$r"
    return
  }
  echo "WARNING: Could not determine region. Using default: eu-west-2" >&2
  CACHED_REGION="eu-west-2"
  echo "$CACHED_REGION"
}

get_instance_id() {
  if [[ -n "$CACHED_INSTANCE_ID" ]]; then
    echo "$CACHED_INSTANCE_ID"
    return
  fi
  CACHED_INSTANCE_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw instance_id 2>&1) || {
    echo "ERROR: Failed to get instance_id from terraform. Run './scripts/appserver.sh deploy' first." >&2
    return 1
  }
  echo "$CACHED_INSTANCE_ID"
}

# Mask AWS account IDs (12-digit sequences in ARNs/S3 URLs) in command output
mask_account_ids() {
  sed -E 's/(arn:aws:[^:]*:[^:]*:)[0-9]{12}:/\1****:/g; s/(appserver-[a-z]+-)[0-9]{12}(-)/\1****\2/g'
}

get_state_bucket() {
  local region account_id
  region="$(get_region)"
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region") \
    || die "Failed to get AWS account ID"
  echo "appserver-tfstate-${account_id}-${region}"
}

get_artifacts_bucket() {
  local region account_id
  region="$(get_region)"
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region") \
    || die "Failed to get AWS account ID"
  echo "appserver-artifacts-${account_id}-${region}"
}

# Run a command on the instance via SSM and return stdout.
# Usage: ssm_run <command_string> [timeout_seconds]

# --- Sourced libraries ---
#
# Each lib defines a focused subset of helpers + subcommands. See
# the header of each file for what's in it. Order matters: ssm.sh
# uses cloudflare.sh's check_cloudflare_ip_drift in cmd_config_push,
# threats.sh uses ssm_run + cf_api.

# shellcheck source=lib/cloudflare.sh
source "$SCRIPT_DIR/lib/cloudflare.sh"
# shellcheck source=lib/auth.sh
source "$SCRIPT_DIR/lib/auth.sh"
# shellcheck source=lib/iam.sh
source "$SCRIPT_DIR/lib/iam.sh"
# shellcheck source=lib/ssm.sh
source "$SCRIPT_DIR/lib/ssm.sh"
# shellcheck source=lib/threats.sh
source "$SCRIPT_DIR/lib/threats.sh"

package_and_upload_artifact() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_artifacts_bucket)"

  local tmpdir
  tmpdir=$(mktemp -d) || die "Failed to create temp directory"
  trap 'rm -rf "$tmpdir"' RETURN

  # Create artifact directory structure
  mkdir -p "$tmpdir/appserver-artifact/traefik"
  mkdir -p "$tmpdir/appserver-artifact/apps"

  # Copy traefik config (includes dynamic/ middleware directory)
  cp -r "$CONFIG_DIR/traefik/"* "$tmpdir/appserver-artifact/traefik/" 2>/dev/null || true

  # Copy app configs (compose files + env examples, NOT .env secrets)
  if [[ -d "$CONFIG_DIR/apps" ]]; then
    for app_dir in "$CONFIG_DIR/apps"/*/; do
      [[ -d "$app_dir" ]] || continue
      local app_name
      app_name=$(basename "$app_dir")
      mkdir -p "$tmpdir/appserver-artifact/apps/$app_name"
      cp "$app_dir"docker-compose.yml "$tmpdir/appserver-artifact/apps/$app_name/" 2>/dev/null || true
      cp "$app_dir".env.example "$tmpdir/appserver-artifact/apps/$app_name/" 2>/dev/null || true
      # Do NOT copy .env (secrets)
    done
  fi

  # Create tarball
  tar czf "$tmpdir/appserver-artifact.tar.gz" -C "$tmpdir" appserver-artifact/ \
    || die "Failed to create artifact tarball"

  # Generate SHA256 checksum
  (cd "$tmpdir" && sha256sum appserver-artifact.tar.gz > appserver-artifact.tar.gz.sha256) \
    || die "Failed to generate artifact checksum"

  # Upload to S3
  echo "  Uploading artifact to S3..."
  aws s3 cp "$tmpdir/appserver-artifact.tar.gz" \
    "s3://$bucket/deploy/appserver-artifact.tar.gz" \
    --region "$region" --quiet || {
    echo "ERROR: Failed to upload artifact to S3" >&2
    return 1
  }
  aws s3 cp "$tmpdir/appserver-artifact.tar.gz.sha256" \
    "s3://$bucket/deploy/appserver-artifact.tar.gz.sha256" \
    --region "$region" --quiet
  echo "  Artifact uploaded (with checksum)."

  # Upload cloudflared binary to S3 as fallback for bootstrap
  local cf_version
  cf_version=$(grep '^cloudflared_version' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*= *"//;s/"//' || true)
  [[ -z "$cf_version" ]] && cf_version=$(grep -A3 'variable "cloudflared_version"' "$TERRAFORM_DIR/variables.tf" | grep default | sed 's/.*= *"//;s/"//' || true)
  if [[ -n "$cf_version" ]]; then
    echo "  Downloading cloudflared $cf_version for S3 fallback..."
    local cf_sha256
    cf_sha256=$(grep '^cloudflared_sha256' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*= *"//;s/"//' || true)
    [[ -z "$cf_sha256" ]] && cf_sha256=$(grep -A3 'variable "cloudflared_sha256"' "$TERRAFORM_DIR/variables.tf" | grep default | sed 's/.*= *"//;s/"//' || true)

    if curl -fsSL --retry 3 --retry-delay 5 \
      "https://github.com/cloudflare/cloudflared/releases/download/$cf_version/cloudflared-linux-arm64" \
      -o "$tmpdir/cloudflared-linux-arm64"; then
      if [[ -n "$cf_sha256" ]]; then
        local actual_sha
        actual_sha=$(sha256sum "$tmpdir/cloudflared-linux-arm64" | awk '{print $1}')
        if [[ "$actual_sha" != "$cf_sha256" ]]; then
          echo "  WARNING: cloudflared checksum mismatch — skipping S3 upload"
          echo "  Expected: $cf_sha256"
          echo "  Got:      $actual_sha"
        else
          aws s3 cp "$tmpdir/cloudflared-linux-arm64" \
            "s3://$bucket/deploy/cloudflared-linux-arm64" \
            --region "$region" --quiet
          echo "  cloudflared uploaded to S3 fallback (checksum verified)."
        fi
      else
        aws s3 cp "$tmpdir/cloudflared-linux-arm64" \
          "s3://$bucket/deploy/cloudflared-linux-arm64" \
          --region "$region" --quiet
        echo "  cloudflared uploaded to S3 fallback (no checksum configured)."
      fi
    else
      echo "  WARNING: Could not download cloudflared for S3 fallback (GitHub may be unavailable)"
    fi
  fi

  # tmpdir cleaned up by RETURN trap
}

# --- Subcommands ---

cmd_init() {
  # init bootstraps the AWS infrastructure prerequisites (IAM policies,
  # deployer user + access keys, state bucket). It requires admin-level AWS
  # credentials — the deployer user cannot create its own policies. If the
  # deployer profile is active, unset it so the default credential chain
  # resolves admin credentials instead.
  if [[ "${AWS_PROFILE:-}" == "appserver" ]]; then
    unset AWS_PROFILE
  fi

  # 004: every admin operation requires an MFA-derived session. The
  # AppserverAdmin policy explicit-denies all actions outside a small
  # safe-list (sts:GetSessionToken, MFA management, self-introspection)
  # when aws:MultiFactorAuthPresent is false. admin_mfa_session() mints
  # the session via sts:GetSessionToken and exports AWS_PROFILE.
  load_env  # pick up APPSERVER_ADMIN_MFA_SERIAL from terraform local-env
  admin_mfa_session

  echo "Appserver Setup"
  echo "==============="
  echo

  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    echo "Existing terraform.tfvars found."
    read -rp "Overwrite? [y/N]: " overwrite
    if [[ "$overwrite" == [yY] ]]; then
      cmd_setup_local --force
    fi
  else
    cmd_setup_local
  fi

  [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]] \
    || die "terraform.tfvars missing. Run: ./scripts/appserver.sh setup local"

  load_env

  echo
  echo "Checking prerequisites..."
  ensure_deployer_access
  ensure_state_backend

  echo
  echo "Setup complete. Run: ./scripts/appserver.sh deploy"
}

cmd_deploy() {
  check_dependencies
  load_env

  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  echo "Running terraform..."
  cd "$TERRAFORM_DIR" || die "Cannot cd to terraform directory"
  terraform init \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true" \
    -reconfigure \
    -input=false 2>&1 | mask_account_ids
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform init failed"

  # Import orphaned artifacts bucket if it exists but isn't in state
  # (happens when a previous destroy deleted state but the bucket survived)
  local artifacts_bucket
  artifacts_bucket="$(get_artifacts_bucket)"
  if aws s3api head-bucket --bucket "$artifacts_bucket" --region "$region" 2>/dev/null \
     && ! terraform state show aws_s3_bucket.artifacts &>/dev/null; then
    echo "Importing existing artifacts bucket into state..."
    terraform import aws_s3_bucket.artifacts "$artifacts_bucket" 2>&1 | mask_account_ids
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform import failed"
  fi

  terraform apply -input=false -auto-approve 2>&1 | mask_account_ids
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform apply failed — see output above. Artifacts NOT uploaded."

  echo
  echo "Uploading artifacts..."
  package_and_upload_artifact

  echo
  echo "Deploy complete."
  echo "First boot takes ~3 minutes. Check with: ./scripts/appserver.sh status"
}

cmd_destroy() {
  check_dependencies
  load_env

  # Destroy needs admin (NOT deploy-role) because it has to delete the
  # operator-role boundary policies. The deploy role is bounded by
  # operator_deploy_boundary which contains DenyOperatorPolicyMutation —
  # the deploy role cannot delete the policy that bounds it. Self-eating
  # by design (Finding 2 from spec 003). Mirror cmd_init's auth pattern:
  # mint an MFA-derived admin session via sts:GetSessionToken.
  if [[ "${AWS_PROFILE:-}" == appserver-* && "${AWS_PROFILE:-}" != appserver-admin-mfa ]]; then
    unset AWS_PROFILE
  fi
  admin_mfa_session

  echo "This will destroy ALL appserver infrastructure."
  read -rp "Type 'destroy' to confirm: " confirm
  [[ "$confirm" == "destroy" ]] || { echo "Aborted."; return 1; }

  local region
  region="$(get_region)"

  # Terraform destroy (skip if deployer credentials or state backend are inaccessible)
  local bucket=""
  bucket="$(get_state_bucket 2>/dev/null)" || true
  if [[ -n "$bucket" ]] && aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    cd "$TERRAFORM_DIR" || die "Cannot cd to terraform directory"
    terraform init \
      -backend-config="bucket=$bucket" \
      -backend-config="region=$region" \
      -backend-config="use_lockfile=true" \
      -reconfigure \
      -input=false 2>&1 | mask_account_ids
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform init failed"

    # Snapshot state to S3 before destroy — last-resort recovery if the
    # destroy goes wrong or wipes something we wanted to keep. Saved
    # alongside the active state, prefixed by timestamp.
    local snapshot_local snapshot_key
    snapshot_local="$(mktemp -t tf-state-snapshot.XXXXXX.tfstate)"
    snapshot_key="state-snapshots/destroy-$(date -u +%Y%m%dT%H%M%SZ).tfstate"
    if terraform state pull > "$snapshot_local" 2>/dev/null && [[ -s "$snapshot_local" ]]; then
      if aws s3 cp "$snapshot_local" "s3://$bucket/$snapshot_key" --region "$region" >/dev/null 2>&1; then
        echo "State snapshot saved: s3://$bucket/$snapshot_key"
      fi
    fi
    rm -f "$snapshot_local"

    # Disable EC2 termination protection before destroy (it blocks terraform destroy)
    local instance_id
    instance_id="$(terraform output -json instance_id 2>/dev/null | jq -r '.')" || true
    if [[ -n "$instance_id" ]]; then
      echo "Disabling termination protection on $instance_id..."
      aws ec2 modify-instance-attribute \
        --instance-id "$instance_id" \
        --no-disable-api-termination \
        --region "$region" 2>/dev/null || true
    fi

    # force_destroy=true lets Terraform delete S3 buckets that contain objects.
    # Apply it first — destroy alone won't update the attribute before deleting.
    terraform apply -input=false -auto-approve \
      -var "force_destroy=true" \
      -target="aws_s3_bucket.artifacts" 2>&1 | mask_account_ids
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform apply (force_destroy) failed"
    terraform destroy -input=false -auto-approve \
      -var "force_destroy=true" 2>&1 | mask_account_ids
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || die "terraform destroy failed"
    echo "Infrastructure destroyed."
  else
    echo "State backend unavailable — skipping terraform destroy."
    echo "If resources still exist, destroy them manually or restore access first."
  fi

  echo
  read -rp "Also remove bootstrap resources (IAM deployer, policies, state bucket)? [y/N] " cleanup
  [[ "$cleanup" =~ ^[Yy]$ ]] || { echo "Bootstrap resources kept."; return 0; }

  echo "Cleaning up bootstrap resources..."

  # Switch away from the deployer profile — the deployer cannot delete itself
  unset AWS_PROFILE
  local account_id caller_user
  local caller_identity
  caller_identity=$(aws sts get-caller-identity --output json) \
    || die "Failed to get caller identity — ensure your default AWS profile has admin permissions"
  account_id=$(echo "$caller_identity" | jq -r '.Account')
  caller_user=$(echo "$caller_identity" | jq -r '.Arn' | sed 's|.*/||')

  # Derive state bucket name now that we have working credentials
  local bucket="appserver-tfstate-${account_id}-${region}"

  local deployer_user="appserver-deployer"
  # Includes AppserverDeployerAssumeRoles (added in the IAM scoping rollout)
  # so cleanup-bootstrap fully removes deployer-tier policies.
  local deployer_policies=(
    "AppserverDeployerCompute"
    "AppserverDeployerIamSsm"
    "AppserverDeployerMonitoringStorage"
    "AppserverDeployerAssumeRoles"
  )
  # Subset attached to the calling user (admin); AssumeRoles is deployer-only.
  local caller_deployer_policies=(
    "AppserverDeployerCompute"
    "AppserverDeployerIamSsm"
    "AppserverDeployerMonitoringStorage"
  )

  # Detach policies from deployer user and delete access keys
  if aws iam get-user --user-name "$deployer_user" &>/dev/null; then
    local keys
    keys=$(aws iam list-access-keys --user-name "$deployer_user" --query 'AccessKeyMetadata[].AccessKeyId' --output text) || true
    for key in $keys; do
      aws iam delete-access-key --user-name "$deployer_user" --access-key-id "$key" 2>/dev/null || true
      echo "  Access key ........... deleted"
    done
    for name in "${deployer_policies[@]}"; do
      aws iam detach-user-policy --user-name "$deployer_user" \
        --policy-arn "arn:aws:iam::${account_id}:policy/${name}" 2>/dev/null || true
    done
    aws iam delete-user --user-name "$deployer_user" 2>/dev/null \
      && echo "  IAM user ............. deleted ($deployer_user)" \
      || echo "  IAM user ............. failed to delete ($deployer_user)"
  else
    echo "  IAM user ............. already gone ($deployer_user)"
  fi

  # Empty and delete artifacts bucket (terraform may have left it if state was lost)
  local artifacts_bucket="appserver-artifacts-${account_id}-${region}"
  local artifacts_status
  artifacts_status=$(aws s3api head-bucket --bucket "$artifacts_bucket" 2>&1; echo "EXIT:$?")
  if echo "$artifacts_status" | grep -q "EXIT:0"; then
    echo "  Artifacts bucket ..... emptying"
    aws s3api list-object-versions --bucket "$artifacts_bucket" --output json 2>/dev/null \
      | jq -r '.Versions[]? | "\(.Key)\t\(.VersionId)"' \
      | while IFS=$'\t' read -r key vid; do
          aws s3api delete-object --bucket "$artifacts_bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
    aws s3api list-object-versions --bucket "$artifacts_bucket" --output json 2>/dev/null \
      | jq -r '.DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' \
      | while IFS=$'\t' read -r key vid; do
          aws s3api delete-object --bucket "$artifacts_bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
    aws s3 rb "s3://$artifacts_bucket" 2>/dev/null \
      && echo "  Artifacts bucket ..... deleted" \
      || echo "  Artifacts bucket ..... failed to delete"
  elif echo "$artifacts_status" | grep -q "403\|Forbidden\|AccessDenied"; then
    echo "  Artifacts bucket ..... exists but access denied"
  else
    echo "  Artifacts bucket ..... already gone"
  fi

  # Empty and delete state bucket (before deleting admin policy that grants S3 access)
  local bucket_status
  bucket_status=$(aws s3api head-bucket --bucket "$bucket" 2>&1; echo "EXIT:$?")
  if echo "$bucket_status" | grep -q "EXIT:0"; then
    echo "  State bucket ......... emptying"
    aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null \
      | jq -r '.Versions[]? | "\(.Key)\t\(.VersionId)"' \
      | while IFS=$'\t' read -r key vid; do
          aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
    aws s3api list-object-versions --bucket "$bucket" --output json 2>/dev/null \
      | jq -r '.DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' \
      | while IFS=$'\t' read -r key vid; do
          aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" 2>/dev/null || true
        done
    aws s3 rb "s3://$bucket" 2>/dev/null \
      && echo "  State bucket ......... deleted" \
      || echo "  State bucket ......... failed to delete"
  elif echo "$bucket_status" | grep -q "403\|Forbidden\|AccessDenied"; then
    echo "  State bucket ......... exists but access denied"
    echo "  Delete manually with an admin profile (bucket name in terraform output)"
  else
    echo "  State bucket ......... already gone ($bucket)"
  fi

  # Detach legacy deployer policies from the calling user (AssumeRoles was
  # never attached to the caller, so it's not in this loop), then delete all
  # deployer policies.
  for name in "${caller_deployer_policies[@]}"; do
    aws iam detach-user-policy --user-name "$caller_user" \
      --policy-arn "arn:aws:iam::${account_id}:policy/${name}" 2>/dev/null || true
  done
  for name in "${deployer_policies[@]}"; do
    local arn="arn:aws:iam::${account_id}:policy/${name}"
    delete_all_policy_versions "$arn" 2>/dev/null || true
    if aws iam delete-policy --policy-arn "$arn" 2>/dev/null; then
      echo "  IAM policy ........... deleted ($name)"
    fi
  done
  echo "  IAM policy ........... kept (AppserverAdmin — needed for re-init)"

  # Remove appserver AWS profile
  if command -v python3 &>/dev/null; then
    if python3 -c "
import configparser, os, sys
for path, style in [('credentials', False), ('config', True)]:
    fpath = os.path.expanduser(f'~/.aws/{path}')
    if not os.path.isfile(fpath): continue
    cp = configparser.ConfigParser()
    cp.read(fpath)
    section = 'profile appserver' if style else 'appserver'
    if cp.has_section(section):
        cp.remove_section(section)
        with open(fpath, 'w') as f: cp.write(f)
" 2>/dev/null; then
      echo "  AWS profile .......... removed (appserver)"
    fi
  fi

  echo "Full cleanup complete."
}


cmd_start() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Starting instance..."
  aws ec2 start-instances --instance-ids "$instance_id" --region "$region" >/dev/null
  echo "Instance starting. Services will be ready in ~60s."
}

cmd_stop() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Stopping instance..."
  aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" >/dev/null
  echo "Instance stopping."
}


cmd_spend() {
  local region
  region="$(get_region)"
  local start_date end_date
  start_date=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d)
  end_date=$(date +%Y-%m-%d)

  echo "AWS costs (last 30 days):"
  aws ce get-cost-and-usage \
    --time-period "Start=$start_date,End=$end_date" \
    --granularity MONTHLY \
    --metrics BlendedCost \
    --filter '{"Tags":{"Key":"Project","Values":["appserver"]}}' \
    --region us-east-1 \
    --query 'ResultsByTime[].Total.BlendedCost.{Amount:Amount,Unit:Unit}' \
    --output table 2>/dev/null || echo "  (Cost Explorer not available or no data yet)"
}


# --- Setup ---

cmd_setup_local() {
  # Write local machine config: terraform/.env (CF API token) and
  # terraform/terraform.tfvars (region, domain, CF IDs, email, subdomains).
  # Pure local — makes no AWS calls, safe to run before any AWS credentials
  # are configured.
  local force=""
  if [[ "${1:-}" == "--force" ]]; then
    force=1
  fi

  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" && -z "$force" ]]; then
    echo "Existing terraform.tfvars found."
    read -rp "Overwrite? [y/N]: " overwrite
    if [[ "$overwrite" != [yY] ]]; then
      echo "Kept existing config."
      return 0
    fi
  fi

  read -rp "AWS region [eu-west-2]: " region
  region="${region:-eu-west-2}"
  [[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] \
    || die "Invalid AWS region format: $region"

  read -rp "Base domain (e.g. example.com): " domain
  [[ -n "$domain" ]] || die "Domain is required."
  [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]] \
    || die "Invalid domain format: $domain"

  read -rp "Cloudflare Zone ID: " cf_zone_id
  [[ -n "$cf_zone_id" ]] || die "Zone ID is required."
  [[ "$cf_zone_id" =~ ^[0-9a-f]{32}$ ]] \
    || die "Zone ID must be a 32-character hex string"

  read -rp "Cloudflare Account ID: " cf_account_id
  [[ -n "$cf_account_id" ]] || die "Account ID is required."
  [[ "$cf_account_id" =~ ^[0-9a-f]{32}$ ]] \
    || die "Account ID must be a 32-character hex string"

  read -rp "Cloudflare API Token: " cf_api_token
  [[ -n "$cf_api_token" ]] || die "API Token is required."

  read -rp "Admin email [you@example.com]: " email
  email="${email:-you@example.com}"
  [[ "$email" != "you@example.com" ]] || die "Admin email must be set — placeholder rejected."
  [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] \
    || die "Invalid email format: $email"

  read -rp "App subdomains (comma-separated) [cookie]: " subdomains
  subdomains="${subdomains:-cookie}"

  local tf_subdomains
  tf_subdomains=$(echo "$subdomains" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk '{printf "  \"%s\",\n", $0}')

  (
    umask 077
    cat > "$ENV_FILE" <<EOF
export CLOUDFLARE_API_TOKEN="$cf_api_token"
EOF
  )

  cat > "$TERRAFORM_DIR/terraform.tfvars" <<EOF
region                = "$region"
domain                = "$domain"
cloudflare_zone_id    = "$cf_zone_id"
cloudflare_account_id = "$cf_account_id"
admin_email           = "$email"
app_subdomains        = [
$tf_subdomains]
EOF

  echo "  Config ............... written (terraform.tfvars + .env)"
}

cmd_setup_unlock() {
  if ! command -v git-crypt &>/dev/null; then
    die "git-crypt not found. Install it first: https://github.com/AGWA/git-crypt"
  fi

  # Check if already unlocked by testing if an encrypted file is readable text
  local test_file
  test_file=$(git-crypt status 2>/dev/null | grep "^    encrypted:" | head -1 | sed 's/^    encrypted: *//')
  if [[ -n "$test_file" && -f "$test_file" ]] && file -b "$test_file" | grep -qi text; then
    echo "Already unlocked — encrypted files are readable:"
    git-crypt status 2>/dev/null | grep "^    encrypted:" | sed 's/^    encrypted: */  /'
    return 0
  fi

  local key_file="${1:-}"

  if [[ -n "$key_file" ]]; then
    # Unlock with provided key file
    [[ -f "$key_file" ]] || die "Key file not found: $key_file"
    git-crypt unlock "$key_file"
    echo "Unlocked with key file."
  else
    # Fetch key from SSM
    echo "Fetching git-crypt key from SSM..."
    local region
    region="$(get_region)"
    local tmpkey
    tmpkey=$(mktemp) || die "Failed to create temp file"
    trap 'rm -f "$tmpkey"' RETURN

    aws ssm get-parameter \
      --name /appserver/git-crypt-key \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --region "$region" \
      | base64 -d > "$tmpkey" \
      || die "Failed to fetch key from SSM. Do you have access to /appserver/git-crypt-key?"

    git-crypt unlock "$tmpkey"
    echo "Unlocked with key from SSM."
  fi

  echo
  echo "Encrypted files now readable:"
  git-crypt status | grep "encrypted:" || true
}

cmd_setup_lock() {
  if ! command -v git-crypt &>/dev/null; then
    die "git-crypt not found."
  fi
  git-crypt lock --force
  echo "Locked — encrypted files are now opaque."
}

cmd_setup() {
  case "${1:-}" in
    local)   shift; cmd_setup_local "$@" ;;
    unlock)  cmd_setup_unlock "${2:-}" ;;
    lock)    cmd_setup_lock ;;
    *)
      echo "Usage: appserver setup {local|unlock [key-file]|lock}"
      echo
      echo "  local [--force]     Interactively write terraform/.env + tfvars (no AWS calls)"
      echo "  unlock              Fetch key from SSM and decrypt pentest targets"
      echo "  unlock <key-file>   Decrypt using a local key file"
      echo "  lock                Re-encrypt files in working tree"
      ;;
  esac
}

# Top-level shortcut: list registered Cookie users (passkey accounts).

# --- Main ---

# Map each subcommand identifier to the operator role required to run it.
# `auth` subcommand IS the auth call; `init`, `setup local`, `setup lock`,
# and `config check-ips` don't touch AWS so are deliberately excluded.
declare -A SUBCOMMAND_ROLE=(
  # Pure AWS reads (no SSM SendCommand) — readonly role.
  [spend]=readonly
  [threats_default]=readonly
  [threats_blocked]=readonly
  [threats_allowed]=readonly
  [threats_list]=readonly
  [threats_report]=readonly
  [setup_unlock]=readonly
  # Run shell on the instance via SSM SendCommand (status/health/users/logs/
  # app_list all use ssm_run). SendCommand is effectively a write API even
  # for "read-only" commands like docker ps, so these escalate to cookie-ops.
  # See specs/003-iam-mfa-scoping/spec.md security review Finding 1.
  [status]=cookie-ops
  [health]=cookie-ops
  [users]=cookie-ops
  [logs]=cookie-ops
  [app_list]=cookie-ops
  [app_deploy]=cookie-ops
  [app_init]=cookie-ops
  [app_remove]=cookie-ops
  [app_restart]=cookie-ops
  [app_env]=cookie-ops
  [config_push]=cookie-ops
  [threats_block]=cookie-ops
  [threats_unblock]=cookie-ops
  [threats_allow]=cookie-ops
  [threats_unallow]=cookie-ops
  [deploy]=deploy
  # destroy is NOT in this map — it requires admin (not deploy-role)
  # because it has to delete the boundary policies that bound the deploy
  # role itself. cmd_destroy calls admin_mfa_session() directly. Same
  # rationale as init.
  [start]=deploy
  [stop]=deploy
  [ssh]=deploy
)

# Wrapper to ensure the right role's session is active before the
# subcommand runs. Use as: with_role <key> <cmd_function> [args...].
with_role() {
  local key="$1"; shift
  local role="${SUBCOMMAND_ROLE[$key]:-}"
  [[ -n "$role" ]] && ensure_session_valid_for_role "$role"
  "$@"
}

# When this script is sourced (e.g. by tests/auth-flow-test.sh) all
# function definitions and the SUBCOMMAND_ROLE map are exposed but the
# dispatcher below is skipped — sourcing should not run any subcommand.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  # shellcheck disable=SC2317  # `|| true` is reached if `return` errors when not sourced
  return 0 2>/dev/null || true
fi

check_dependencies
load_env

case "${1:-}" in
  auth)     shift; cmd_auth "$@" ;;
  init)     cmd_init ;;
  deploy)   with_role deploy   cmd_deploy ;;
  destroy)  cmd_destroy ;;  # admin-only; cmd_destroy calls admin_mfa_session
  status)   with_role status   cmd_status ;;
  health)   with_role health   cmd_health ;;
  users)    with_role users    cmd_users ;;
  start)    with_role start    cmd_start ;;
  stop)     with_role stop     cmd_stop ;;
  ssh)      with_role ssh      cmd_ssh ;;
  logs)     with_role logs     cmd_logs "${2:-}" ;;
  spend)    with_role spend    cmd_spend ;;
  threats)
    case "${2:-}" in
      block)    shift 2; with_role threats_block    cmd_threats_block "$@" ;;
      unblock)  shift 2; with_role threats_unblock  cmd_threats_unblock "$@" ;;
      blocked)  shift 2; with_role threats_blocked  cmd_threats_blocked "$@" ;;
      allow)    shift 2; with_role threats_allow    cmd_threats_allow "$@" ;;
      unallow)  shift 2; with_role threats_unallow  cmd_threats_unallow "$@" ;;
      allowed)  shift 2; with_role threats_allowed  cmd_threats_allowed "$@" ;;
      list)     shift 2; with_role threats_list     cmd_threats_list "$@" ;;
      report)   shift 2; with_role threats_report   cmd_threats_report "$@" ;;
      *)        shift;   with_role threats_default  cmd_threats "$@" ;;
    esac
    ;;
  setup)
    case "${2:-}" in
      unlock)   shift 2; with_role setup_unlock cmd_setup_unlock "$@" ;;
      *)        shift;   cmd_setup "$@" ;;
    esac
    ;;
  config)
    case "${2:-}" in
      push)      with_role config_push cmd_config_push ;;
      check-ips) cmd_config_check_ips "${3:-}" ;;
      *)         echo "Usage: appserver config {push|check-ips [--fix]}" ;;
    esac
    ;;
  app)
    case "${2:-}" in
      init)    with_role app_init    cmd_app_init "${3:-}" ;;
      deploy)  with_role app_deploy  cmd_app_deploy "${3:-}" ;;
      restart) with_role app_restart cmd_app_restart "${3:-}" ;;
      list)    with_role app_list    cmd_app_list ;;
      remove)  with_role app_remove  cmd_app_remove "${3:-}" ;;
      env)     shift 2; with_role app_env cmd_app_env "$@" ;;
      *)       echo "Usage: appserver app {init|deploy|restart|list|remove|env} [name] [args...]" ;;
    esac
    ;;
  *)
    echo "Appserver — Docker app hosting on EC2 behind Cloudflare"
    echo
    echo "Usage: $(basename "$0") <command>"
    echo
    echo "Auth:"
    echo "  auth [--role <r>]   Assume an IAM role via MFA (1-hour STS session)"
    echo "                      Roles: readonly, cookie-ops, deploy"
    echo "  auth status         Show active role sessions and time remaining"
    echo
    echo "Infrastructure:"
    echo "  init          Interactive setup (IAM, state bucket, config)"
    echo "  deploy        Terraform apply (provision/update infrastructure)"
    echo "  destroy       Terraform destroy (with confirmation)"
    echo
    echo "Instance:"
    echo "  status        Show running containers and resource usage"
    echo "  health        Unified health summary (instance + containers + Cookie + last threat report)"
    echo "  users         List Cookie users (passkey accounts)"
    echo "  start         Start EC2 instance"
    echo "  stop          Stop EC2 instance"
    echo "  ssh           SSM session to instance"
    echo "  logs [app|bootstrap]  Container logs, or bootstrap for /var/log/appserver-bootstrap.log"
    echo "  spend         AWS cost breakdown"
    echo
    echo "Apps:"
    echo "  app init <name>              Generate secrets and create .env on instance"
    echo "  app deploy <name>            Pull latest image and restart"
    echo "  app restart <name>           Restart app containers"
    echo "  app list                     Show all apps and status"
    echo "  app remove <name>            Stop and remove app"
    echo "  app env <name> [KEY=VALUE]   View/set environment variables"
    echo
    echo "Threats:"
    echo "  threats [--since <dur>]      Analyze access logs for threats (default: 24h)"
    echo "  threats report [<timestamp>] View a threat report (default: latest)"
    echo "  threats list                 List all threat reports"
    echo "  threats block <ip> [--note]  Block IP via Cloudflare WAF"
    echo "  threats unblock <ip>         Unblock IP"
    echo "  threats blocked              List blocked IPs"
    echo "  threats allow [<ip>]         Allowlist IP in CF WAF (defaults to your public IP — for pentests)"
    echo "  threats unallow <ip>         Remove allowlist rule"
    echo "  threats allowed              List allowlisted IPs"
    echo
    echo "Config:"
    echo "  config push              Upload config to instance and restart Traefik"
    echo "  config check-ips [--fix] Audit Cloudflare IP ranges in traefik.yml"
    echo
    echo "Setup:"
    echo "  setup local [--force]    Write terraform/.env + tfvars (for existing infra, no AWS admin)"
    echo "  setup unlock [key-file]  Decrypt pentest targets (fetches key from SSM)"
    echo "  setup lock               Re-encrypt files in working tree"
    ;;
esac
