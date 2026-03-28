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

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$cmd_string\"]}" \
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
    echo "  2. IAM -> Users -> $caller_user -> Attach policies -> AppserverAdmin"
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
    export AWS_PROFILE=appserver

    echo "  Access keys .......... created (profile 'appserver' configured)"
  fi
}

ensure_state_backend() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  if aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    echo "  State bucket ......... ok ($bucket)"
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null || {
      echo "ERROR: Failed to create S3 state bucket '$bucket'" >&2
      return 1
    }

    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --region "$region" \
      --versioning-configuration Status=Enabled \
      || die "Failed to enable bucket versioning on $bucket"

    aws s3api put-bucket-encryption \
      --bucket "$bucket" \
      --region "$region" \
      --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}, "BucketKeyEnabled": true}]
      }' || die "Failed to enable bucket encryption on $bucket"

    aws s3api put-public-access-block \
      --bucket "$bucket" \
      --region "$region" \
      --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "Failed to set public access block on $bucket"

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
      }" || die "Failed to set bucket policy on $bucket"

    echo "  State bucket ......... created ($bucket)"
  fi
}

package_and_upload_artifact() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_artifacts_bucket)"

  local tmpdir
  tmpdir=$(mktemp -d) || die "Failed to create temp directory"

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
  echo "  Uploading artifact to s3://$bucket/deploy/appserver-artifact.tar.gz..."
  aws s3 cp "$tmpdir/appserver-artifact.tar.gz" \
    "s3://$bucket/deploy/appserver-artifact.tar.gz" \
    --region "$region" --quiet || {
    echo "ERROR: Failed to upload artifact to S3" >&2
    rm -rf "$tmpdir"
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
    if curl -fsSL --retry 3 --retry-delay 5 \
      "https://github.com/cloudflare/cloudflared/releases/download/$cf_version/cloudflared-linux-arm64" \
      -o "$tmpdir/cloudflared-linux-arm64"; then
      aws s3 cp "$tmpdir/cloudflared-linux-arm64" \
        "s3://$bucket/deploy/cloudflared-linux-arm64" \
        --region "$region" --quiet
      echo "  cloudflared uploaded to S3 fallback."
    else
      echo "  WARNING: Could not download cloudflared for S3 fallback (GitHub may be unavailable)"
    fi
  fi

  rm -rf "$tmpdir"
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

  echo "Uploading artifacts..."
  package_and_upload_artifact

  echo "Running terraform..."
  cd "$TERRAFORM_DIR" || die "Cannot cd to terraform directory"
  terraform init \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true" \
    -input=false

  terraform apply -input=false -auto-approve

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

  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  cd "$TERRAFORM_DIR" || die "Cannot cd to terraform directory"
  terraform init \
    -backend-config="bucket=$bucket" \
    -backend-config="region=$region" \
    -backend-config="use_lockfile=true" \
    -input=false

  terraform destroy -input=false -auto-approve

  echo "Infrastructure destroyed."
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
    ssm_run "cd /opt/appserver/apps/$app && docker compose logs --tail=100 2>&1" 60
  else
    ssm_run "echo '=== Traefik ===' && docker logs --tail=30 traefik 2>&1 && for d in /opt/appserver/apps/*/; do [ -d \"\$d\" ] || continue; app=\$(basename \"\$d\"); echo && echo \"=== \$app ===\"; cd \"\$d\" && docker compose logs --tail=20 2>&1; done" 60
  fi
}

cmd_app_deploy() {
  local app="${1:?Usage: appserver app deploy <name>}"
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
    aws s3 cp \"s3://\$BUCKET/deploy/appserver-artifact.tar.gz\" /tmp/appserver-artifact.tar.gz --region \"\$REGION\"
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
  echo "Removing $app..."
  ssm_run "cd /opt/appserver/apps/$app && docker compose down && rm -rf /opt/appserver/apps/$app" 60
  echo "$app removed. Note: Docker volumes preserved. Remove manually if needed."
}

cmd_config_push() {
  echo "Pushing config to instance..."
  package_and_upload_artifact

  local bucket region
  bucket="$(get_artifacts_bucket)"
  region="$(get_region)"

  ssm_run "
    set -e
    aws s3 cp 's3://$bucket/deploy/appserver-artifact.tar.gz' /tmp/appserver-artifact.tar.gz --region '$region'
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

  if [[ $# -eq 0 ]]; then
    # Show current env
    ssm_run "cat /opt/appserver/apps/$app/.env 2>/dev/null || echo 'No .env file found'" 15
  else
    # Set env vars
    local env_args=""
    for kv in "$@"; do
      env_args="${env_args}echo '${kv}' >> /tmp/appserver-env-new; "
    done
    ssm_run "
      set -e
      touch /opt/appserver/apps/$app/.env
      cp /opt/appserver/apps/$app/.env /tmp/appserver-env-new
      ${env_args}
      mv /tmp/appserver-env-new /opt/appserver/apps/$app/.env
      echo 'Updated .env for $app. Run \"appserver app deploy $app\" to apply.'
    " 15
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
      deploy) cmd_app_deploy "${3:-}" ;;
      list)   cmd_app_list ;;
      remove) cmd_app_remove "${3:-}" ;;
      env)    shift 2; cmd_app_env "$@" ;;
      *)      echo "Usage: appserver app {deploy|list|remove|env} [name] [args...]" ;;
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
    echo "  app deploy <name>            Pull latest image and restart"
    echo "  app list                     Show all apps and status"
    echo "  app remove <name>            Stop and remove app"
    echo "  app env <name> [KEY=VALUE]   View/set environment variables"
    echo
    echo "Config:"
    echo "  config push   Upload config to instance and restart Traefik"
    ;;
esac
