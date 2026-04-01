#!/bin/bash

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)" || { echo "ERROR: terraform/ directory not found" >&2; exit 1; }
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "ERROR: config/ directory not found" >&2; exit 1; }
ENV_FILE="$TERRAFORM_DIR/.env"
CACHED_REGION=""
CACHED_INSTANCE_ID=""

# Use the appserver AWS profile if it exists and no profile is already set
if [[ -z "${AWS_PROFILE:-}" ]] && aws configure list-profiles 2>/dev/null | grep -q '^appserver$'; then
  export AWS_PROFILE=appserver
fi

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
ssm_run() {
  local cmd_string="$1"
  local timeout="${2:-30}"
  local instance_id region cmd_id
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local params
  params=$(jq -n --arg cmd "$cmd_string" '{"commands": [$cmd]}') \
    || { echo "ERROR: Failed to encode command as JSON" >&2; return 1; }

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "$params" \
    --timeout-seconds "$timeout" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  # Poll for completion
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$region" \
      --query 'Status' \
      --output text 2>/dev/null) || true
    case "$status" in
      Success)
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardOutputContent' \
          --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo "ERROR: Command $status" >&2
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardErrorContent' \
          --output text >&2
        return 1
        ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "ERROR: Timed out waiting for command result" >&2
  return 1
}

# --- IAM helpers ---

# Delete all non-default versions of an IAM policy (required before policy deletion)
delete_all_policy_versions() {
  local arn="$1"
  local versions
  versions=$(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text)
  for v in $versions; do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v" 2>/dev/null || true
  done
}

# Create or update an IAM managed policy. Returns 1 if creation fails (bootstrap).
upsert_iam_policy() {
  local name="$1" file="$2" account_id="$3"
  local arn="arn:aws:iam::${account_id}:policy/${name}"

  if aws iam get-policy --policy-arn "$arn" &>/dev/null; then
    delete_all_policy_versions "$arn"
    aws iam create-policy-version \
      --policy-arn "$arn" \
      --policy-document "file://$file" \
      --set-as-default >/dev/null || die "Failed to update IAM policy $name"
    echo "  IAM policy ........... updated ($name)"
  else
    if ! aws iam create-policy \
      --policy-name "$name" \
      --policy-document "file://$file" >/dev/null 2>&1; then
      return 1
    fi
    echo "  IAM policy ........... created ($name)"
  fi
}

# Attach an IAM policy to a user if not already attached
attach_iam_policy() {
  local user="$1" name="$2" account_id="$3"
  local arn="arn:aws:iam::${account_id}:policy/${name}"

  local attached
  attached=$(aws iam list-attached-user-policies --user-name "$user" \
    --query "AttachedPolicies[?PolicyArn=='$arn']" --output text 2>/dev/null) || attached=""
  if echo "$attached" | grep -q "$name"; then
    echo "  Policy attachment .... ok ($name -> $user)"
  else
    aws iam attach-user-policy --user-name "$user" --policy-arn "$arn" \
      || die "Failed to attach policy $name to $user"
    echo "  Policy attachment .... attached ($name -> $user)"
  fi
}

ensure_deployer_access() {
  local deployer_user="appserver-deployer"
  local policy_dir="$TERRAFORM_DIR/deployer-policies"
  local account_id caller_user
  local caller_identity
  caller_identity=$(aws sts get-caller-identity --output json) \
    || die "Failed to get caller identity"
  account_id=$(echo "$caller_identity" | jq -r '.Account')
  caller_user=$(echo "$caller_identity" | jq -r '.Arn' | sed 's|.*/||')
  [[ -n "$account_id" && -n "$caller_user" ]] || die "Failed to parse caller identity"

  # --- Admin policy (self-bootstrapping) ---
  if ! upsert_iam_policy "AppserverAdmin" "$TERRAFORM_DIR/appserver-admin-policy.json" "$account_id"; then
    echo
    echo "ERROR: Cannot create the AppserverAdmin policy."
    echo "First-time bootstrap requires an IAM admin to create and attach it:"
    echo
    echo "  1. IAM -> Policies -> Create policy -> JSON tab"
    echo "     Paste contents of: terraform/appserver-admin-policy.json"
    echo "     Name: AppserverAdmin"
    echo "  2. IAM -> Users -> $caller_user (your admin user) -> Attach policies -> AppserverAdmin"
    echo
    echo "Then re-run: ./scripts/appserver.sh init"
    return 1
  fi
  attach_iam_policy "$caller_user" "AppserverAdmin" "$account_id"

  # --- Deployer policies ---
  local policy_names=("AppserverDeployerCompute" "AppserverDeployerIamSsm" "AppserverDeployerMonitoringStorage")
  local policy_files=("$policy_dir/compute.json" "$policy_dir/iam-ssm.json" "$policy_dir/monitoring-storage.json")

  for i in "${!policy_names[@]}"; do
    upsert_iam_policy "${policy_names[$i]}" "${policy_files[$i]}" "$account_id"
  done

  # --- Deployer user ---
  if aws iam get-user --user-name "$deployer_user" &>/dev/null; then
    echo "  IAM user ............. ok ($deployer_user)"
  else
    aws iam create-user --user-name "$deployer_user" >/dev/null \
      || die "Failed to create IAM user $deployer_user"
    echo "  IAM user ............. created ($deployer_user)"
  fi

  # Attach deployer policies to both the deployer user and the calling user
  for user in "$deployer_user" "$caller_user"; do
    for i in "${!policy_names[@]}"; do
      attach_iam_policy "$user" "${policy_names[$i]}" "$account_id"
    done
  done

  local existing_keys
  existing_keys=$(aws iam list-access-keys --user-name "$deployer_user" --query 'length(AccessKeyMetadata)' --output text) \
    || die "Failed to list access keys for $deployer_user"

  if [[ "$existing_keys" -gt 0 ]]; then
    echo "  Access keys .......... ok (already configured)"
  else
    local key_output
    key_output=$(aws iam create-access-key --user-name "$deployer_user" --output json) \
      || die "Failed to create access key for $deployer_user"
    local access_key secret_key
    access_key=$(echo "$key_output" | jq -r '.AccessKey.AccessKeyId')
    secret_key=$(echo "$key_output" | jq -r '.AccessKey.SecretAccessKey')
    [[ -n "$access_key" && -n "$secret_key" ]] || die "Failed to parse access key output"

    local region
    region="$(get_region)"

    aws configure set aws_access_key_id "$access_key" --profile appserver
    aws configure set aws_secret_access_key "$secret_key" --profile appserver
    aws configure set region "$region" --profile appserver
    aws configure set output json --profile appserver

    echo "  Access keys .......... created (profile 'appserver' configured)"
  fi
}

ensure_state_backend() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  if aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    echo "  State bucket ......... ok"
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null || {
      echo "ERROR: Failed to create S3 state bucket" >&2
      return 1
    }

    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --region "$region" \
      --versioning-configuration Status=Enabled \
      || die "Failed to enable bucket versioning"

    aws s3api put-bucket-encryption \
      --bucket "$bucket" \
      --region "$region" \
      --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}, "BucketKeyEnabled": true}]
      }' || die "Failed to enable bucket encryption"

    aws s3api put-public-access-block \
      --bucket "$bucket" \
      --region "$region" \
      --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "Failed to set public access block"

    aws s3api put-bucket-policy \
      --bucket "$bucket" \
      --region "$region" \
      --policy "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Sid\": \"DenyNonSSL\",
          \"Effect\": \"Deny\",
          \"Principal\": \"*\",
          \"Action\": \"s3:*\",
          \"Resource\": [
            \"arn:aws:s3:::$bucket\",
            \"arn:aws:s3:::$bucket/*\"
          ],
          \"Condition\": {
            \"Bool\": { \"aws:SecureTransport\": \"false\" }
          }
        }]
      }" || die "Failed to set bucket policy"

    echo "  State bucket ......... created"
  fi
}

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

  # Copy traefik config
  cp "$CONFIG_DIR/traefik/"* "$tmpdir/appserver-artifact/traefik/" 2>/dev/null || true

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
  # init manages IAM policies that require admin permissions.
  # If the auto-profile selected the deployer, unset it so we fall back
  # to the default/admin credentials.
  if [[ "${AWS_PROFILE:-}" == "appserver" ]]; then
    unset AWS_PROFILE
  fi

  echo "Appserver Setup"
  echo "==============="
  echo

  for cmd in aws terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: $cmd not found."
      exit 1
    fi
  done

  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    echo "Existing terraform.tfvars found."
    read -rp "Overwrite? [y/N]: " overwrite
    if [[ "$overwrite" != [yY] ]]; then
      load_env
      local region
      region="$(get_region)"

      echo
      echo "Checking prerequisites..."
      ensure_deployer_access
      ensure_state_backend
      echo "  Config ............... ok (using existing terraform.tfvars)"

      echo
      echo "All prerequisites met. Run: ./scripts/appserver.sh deploy"
      return 0
    fi
  fi

  read -rp "AWS region [eu-west-2]: " region
  region="${region:-eu-west-2}"
  if [[ ! "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
    echo "ERROR: Invalid AWS region format: $region"; exit 1
  fi

  read -rp "Base domain (e.g. matthewdeaves.com): " domain
  [[ -z "$domain" ]] && { echo "Domain is required."; exit 1; }
  if [[ ! "$domain" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]]; then
    echo "ERROR: Invalid domain format: $domain"; exit 1
  fi

  read -rp "Cloudflare Zone ID: " cf_zone_id
  [[ -z "$cf_zone_id" ]] && { echo "Zone ID is required."; exit 1; }
  if [[ ! "$cf_zone_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "ERROR: Zone ID must be a 32-character hex string"; exit 1
  fi

  read -rp "Cloudflare Account ID: " cf_account_id
  [[ -z "$cf_account_id" ]] && { echo "Account ID is required."; exit 1; }
  if [[ ! "$cf_account_id" =~ ^[0-9a-f]{32}$ ]]; then
    echo "ERROR: Account ID must be a 32-character hex string"; exit 1
  fi

  read -rp "Cloudflare API Token: " cf_api_token
  [[ -z "$cf_api_token" ]] && { echo "API Token is required."; exit 1; }

  read -rp "Admin email [matt@matthewdeaves.com]: " email
  email="${email:-matt@matthewdeaves.com}"
  if [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo "ERROR: Invalid email format: $email"; exit 1
  fi

  read -rp "App subdomains (comma-separated) [cookie]: " subdomains
  subdomains="${subdomains:-cookie}"

  # Convert comma-separated to terraform list
  local tf_subdomains
  tf_subdomains=$(echo "$subdomains" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk '{printf "  \"%s\",\n", $0}')

  (
    umask 077
    cat > "$ENV_FILE" <<EOF
export CLOUDFLARE_API_TOKEN="$cf_api_token"
EOF
  )
  echo "Written to terraform/.env"

  cat > "$TERRAFORM_DIR/terraform.tfvars" <<EOF
region                = "$region"
domain                = "$domain"
cloudflare_zone_id    = "$cf_zone_id"
cloudflare_account_id = "$cf_account_id"
admin_email           = "$email"
app_subdomains        = [
$tf_subdomains]
EOF

  echo
  echo "Setting up prerequisites..."
  echo "  Config ............... written (terraform.tfvars + .env)"

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

  terraform apply -input=false -auto-approve 2>&1 | mask_account_ids

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

    terraform destroy -input=false -auto-approve 2>&1 | mask_account_ids
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
  local deployer_policies=("AppserverDeployerCompute" "AppserverDeployerIamSsm" "AppserverDeployerMonitoringStorage")

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

  # Detach deployer policies from calling user and delete them
  for name in "${deployer_policies[@]}"; do
    local arn="arn:aws:iam::${account_id}:policy/${name}"
    aws iam detach-user-policy --user-name "$caller_user" --policy-arn "$arn" 2>/dev/null || true
    delete_all_policy_versions "$arn" 2>/dev/null || true
    aws iam delete-policy --policy-arn "$arn" 2>/dev/null \
      && echo "  IAM policy ........... deleted ($name)" \
      || true
  done
  echo "  IAM policy ........... kept (AppserverAdmin — needed for re-init)"

  # Remove appserver AWS profile
  if command -v python3 &>/dev/null; then
    python3 -c "
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
" 2>/dev/null && echo "  AWS profile .......... removed (appserver)" || true
  fi

  echo "Full cleanup complete."
}

cmd_status() {
  echo "Checking appserver status..."
  local stats
  stats=$(ssm_run "echo '=== Docker Containers ===' && docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' && echo && echo '=== Resources ===' && free -m | head -3 && echo && uptime && echo && df -h / | tail -1" 30 2>/dev/null) || {
    echo "Could not reach instance. Is it running?"
    return 1
  }
  echo "$stats"
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

cmd_ssh() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  aws ssm start-session --target "$instance_id" --region "$region"
}

cmd_logs() {
  local app="${1:-}"
  if [[ -n "$app" ]]; then
    [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
    ssm_run "cd /opt/appserver/apps/$app && docker compose logs --tail=100 2>&1" 60 || return 1
  else
    ssm_run "echo '=== Traefik ===' && docker logs --tail=30 traefik 2>&1 && for d in /opt/appserver/apps/*/; do [ -d \"\$d\" ] || continue; app=\$(basename \"\$d\"); echo && echo \"=== \$app ===\"; cd \"\$d\" && docker compose logs --tail=20 2>&1; done" 60 || return 1
  fi
}

cmd_app_deploy() {
  local app="${1:?Usage: appserver app deploy <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Deploying $app..."

  # Upload latest config
  package_and_upload_artifact

  local bucket region
  bucket="$(get_artifacts_bucket)"
  region="$(get_region)"

  # Pull config and deploy on instance
  ssm_run "
    set -e
    BUCKET='$bucket'
    REGION='$region'
    APP='$app'

    # Pull latest artifacts
    aws s3 cp \"s3://\$BUCKET/deploy/appserver-artifact.tar.gz\" /tmp/appserver-artifact.tar.gz --region \"\$REGION\" --quiet
    tar xzf /tmp/appserver-artifact.tar.gz -C /tmp/

    # Update app config (compose file)
    if [ -d \"/tmp/appserver-artifact/apps/\$APP\" ]; then
      mkdir -p /opt/appserver/apps/\$APP
      cp /tmp/appserver-artifact/apps/\$APP/docker-compose.yml /opt/appserver/apps/\$APP/ 2>/dev/null || true
      # Copy .env.example if no .env exists yet
      if [ ! -f /opt/appserver/apps/\$APP/.env ] && [ -f /tmp/appserver-artifact/apps/\$APP/.env.example ]; then
        cp /tmp/appserver-artifact/apps/\$APP/.env.example /opt/appserver/apps/\$APP/.env
        echo 'WARNING: Created .env from .env.example — edit secrets before starting!'
      fi
    else
      echo 'ERROR: No config found for app: '\$APP
      rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
      exit 1
    fi

    # Pull latest image and restart
    cd /opt/appserver/apps/\$APP
    docker compose pull 2>&1
    docker compose up -d 2>&1

    # Wait for containers to start
    sleep 5
    docker compose ps 2>&1

    rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
  " 120

  echo "$app deployed."
}

cmd_app_list() {
  ssm_run "for d in /opt/appserver/apps/*/; do [ -d \"\$d\" ] || continue; app=\$(basename \"\$d\"); status=\$(cd \"\$d\" && docker compose ps --format '{{.Name}}: {{.Status}}' 2>/dev/null); if [ -n \"\$status\" ]; then echo \"\$status\"; else echo \"\$app: not running\"; fi; done" 30
}

cmd_app_remove() {
  local app="${1:?Usage: appserver app remove <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Removing $app..."
  ssm_run "cd /opt/appserver/apps/$app && docker compose down && rm -rf /opt/appserver/apps/$app" 60
  echo "$app removed. Note: Docker volumes preserved. Remove manually if needed."
}

cmd_app_restart() {
  local app="${1:?Usage: appserver app restart <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Restarting $app..."
  ssm_run "cd /opt/appserver/apps/$app && docker compose restart 2>&1" 60
  echo "$app restarted."
}

cmd_app_init() {
  local app="${1:?Usage: appserver app init <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"

  local app_config_dir="$CONFIG_DIR/apps/$app"
  if [[ ! -f "$app_config_dir/.env.example" ]]; then
    die "No .env.example found for app '$app' in config/apps/$app/"
  fi

  echo "Initializing $app..."
  echo

  # Generate cryptographically random secrets
  local postgres_password secret_key
  postgres_password=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32) \
    || die "Failed to generate POSTGRES_PASSWORD"
  secret_key=$(openssl rand -base64 64 | tr -d '/+=' | head -c 50) \
    || die "Failed to generate SECRET_KEY"

  echo "  Generated POSTGRES_PASSWORD (32 chars)"
  echo "  Generated SECRET_KEY (50 chars)"

  # Build the .env from the example, replacing placeholders
  local env_content
  env_content=$(sed \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" \
    -e "s|^SECRET_KEY=.*|SECRET_KEY=$secret_key|" \
    "$app_config_dir/.env.example") || die "Failed to process .env.example"

  # Remove comment lines starting with # (keep only actual env vars)
  env_content=$(echo "$env_content" | grep -v '^#' | grep -v '^$')

  # Merge local secrets file if it exists (upserts over .env.example values)
  local secrets_file="$app_config_dir/.env.secrets"
  if [[ -f "$secrets_file" ]]; then
    echo "  Merging secrets from $secrets_file"
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
      local key="${line%%=*}"
      # Remove existing key then append (escape key for grep literal match)
      local escaped_key
      escaped_key=$(printf '%s' "$key" | sed 's/[.[\\*^$/]/\\&/g')
      env_content=$(echo "$env_content" | grep -v "^${escaped_key}=")
      env_content="$env_content"$'\n'"$line"
    done < "$secrets_file"
    # Clean up any blank lines
    env_content=$(echo "$env_content" | grep -v '^$')
  fi

  echo
  echo "Generated .env for $app:"
  # shellcheck disable=SC2001 # sed needed for per-line masking; ${//} is greedy across newlines
  echo "$env_content" | sed 's/=.*/=***/'
  echo

  # Upload to instance via SSM
  local env_b64
  env_b64=$(echo "$env_content" | base64 -w0) || die "Failed to encode .env"

  ssm_run "
    set -e
    mkdir -p /opt/appserver/apps/$app
    echo '$env_b64' | base64 -d > /opt/appserver/apps/$app/.env
    chmod 600 /opt/appserver/apps/$app/.env
    echo '.env written to /opt/appserver/apps/$app/.env'
  " 30 || die "Failed to upload .env to instance"

  local domain
  domain=$(sed -n 's/^domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) || true
  [[ -z "$domain" ]] && domain="<your-domain>"

  echo "$app initialized. Next steps:"
  echo "  1. appserver app deploy $app"
  echo "  2. Visit https://$app.$domain"
  echo "  3. Register your first passkey (first user becomes admin)"
}

cmd_config_push() {
  echo "Pushing config to instance..."
  package_and_upload_artifact

  local bucket region
  bucket="$(get_artifacts_bucket)"
  region="$(get_region)"

  ssm_run "
    set -e
    aws s3 cp 's3://$bucket/deploy/appserver-artifact.tar.gz' /tmp/appserver-artifact.tar.gz --region '$region' --quiet
    tar xzf /tmp/appserver-artifact.tar.gz -C /tmp/

    # Update traefik config and restart
    cp /tmp/appserver-artifact/traefik/* /opt/appserver/traefik/ 2>/dev/null || true
    cd /opt/appserver/traefik && docker compose up -d 2>&1

    # Update app compose files (does NOT restart apps — use 'app deploy' for that)
    for app_dir in /tmp/appserver-artifact/apps/*/; do
      [ -d \"\$app_dir\" ] || continue
      app=\$(basename \"\$app_dir\")
      mkdir -p /opt/appserver/apps/\$app
      cp \"\$app_dir\"docker-compose.yml /opt/appserver/apps/\$app/ 2>/dev/null || true
    done

    rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
    echo 'Config updated. Use \"appserver app deploy <name>\" to restart apps.'
  " 60
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

cmd_app_env() {
  local app="${1:?Usage: appserver app env <name> [KEY=VALUE ...]}"
  shift

  # Validate app name (alphanumeric + hyphens only)
  if [[ ! "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    die "Invalid app name: $app (must be lowercase alphanumeric with hyphens)"
  fi

  if [[ $# -eq 0 ]]; then
    # Show current env (mask values for security)
    ssm_run "if [ -f /opt/appserver/apps/$app/.env ]; then sed 's/=.*/=***/' /opt/appserver/apps/$app/.env; else echo 'No .env file found'; fi" 30
  else
    # Validate all KEY=VALUE pairs before sending
    for kv in "$@"; do
      if [[ ! "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]; then
        die "Invalid env var format: '$kv' (must be KEY=VALUE, key starts with letter/underscore)"
      fi
    done

    # Build env file content safely via base64
    local env_content
    env_content=$(printf '%s\n' "$@" | base64 -w0) || die "Failed to encode env vars"

    # Extract keys to remove existing entries (upsert, not append)
    local keys_b64
    keys_b64=$(printf '%s\n' "$@" | sed 's/=.*//' | base64 -w0)

    ssm_run "
      set -e
      mkdir -p /opt/appserver/apps/$app
      touch /opt/appserver/apps/$app/.env
      cp /opt/appserver/apps/$app/.env /tmp/appserver-env-new
      # Remove existing keys so we upsert rather than duplicate
      for key in \$(echo '$keys_b64' | base64 -d); do
        escaped_key=\$(printf '%s' \"\$key\" | sed 's/[.[\\\\*^$/]/\\\\&/g')
        sed -i \"/^\${escaped_key}=/d\" /tmp/appserver-env-new
      done
      echo '$env_content' | base64 -d >> /tmp/appserver-env-new
      mv /tmp/appserver-env-new /opt/appserver/apps/$app/.env
      chmod 600 /opt/appserver/apps/$app/.env
      echo 'Updated .env for $app. Run \"appserver app deploy $app\" to apply.'
    " 30
  fi
}

# --- Main ---

check_dependencies
load_env

case "${1:-}" in
  init)     cmd_init ;;
  deploy)   cmd_deploy ;;
  destroy)  cmd_destroy ;;
  status)   cmd_status ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  ssh)      cmd_ssh ;;
  logs)     cmd_logs "${2:-}" ;;
  spend)    cmd_spend ;;
  config)
    case "${2:-}" in
      push) cmd_config_push ;;
      *)    echo "Usage: appserver config push" ;;
    esac
    ;;
  app)
    case "${2:-}" in
      init)    cmd_app_init "${3:-}" ;;
      deploy)  cmd_app_deploy "${3:-}" ;;
      restart) cmd_app_restart "${3:-}" ;;
      list)    cmd_app_list ;;
      remove)  cmd_app_remove "${3:-}" ;;
      env)     shift 2; cmd_app_env "$@" ;;
      *)       echo "Usage: appserver app {init|deploy|restart|list|remove|env} [name] [args...]" ;;
    esac
    ;;
  *)
    echo "Appserver — Docker app hosting on EC2 behind Cloudflare"
    echo
    echo "Usage: $(basename "$0") <command>"
    echo
    echo "Infrastructure:"
    echo "  init          Interactive setup (IAM, state bucket, config)"
    echo "  deploy        Terraform apply (provision/update infrastructure)"
    echo "  destroy       Terraform destroy (with confirmation)"
    echo
    echo "Instance:"
    echo "  status        Show running containers and resource usage"
    echo "  start         Start EC2 instance"
    echo "  stop          Stop EC2 instance"
    echo "  ssh           SSM session to instance"
    echo "  logs [app]    Stream container logs"
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
    echo "Config:"
    echo "  config push   Upload config to instance and restart Traefik"
    ;;
esac
