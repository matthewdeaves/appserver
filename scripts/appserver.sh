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

# --- Cloudflare API helper ---

get_zone_id() {
  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    local z
    z=$(sed -n 's/^cloudflare_zone_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) && [[ -n "$z" ]] && {
      echo "$z"
      return
    }
  fi
  die "Could not read cloudflare_zone_id from terraform.tfvars"
}

# Make authenticated Cloudflare API v4 requests.
# Usage: cf_api <method> <endpoint> [json_body]
# Returns JSON response. Dies on missing credentials.
cf_api() {
  local method="$1" endpoint="$2" body="${3:-}"
  local token="${CLOUDFLARE_API_TOKEN:-}"
  [[ -n "$token" ]] || die "CLOUDFLARE_API_TOKEN not set"

  local zone_id
  zone_id="$(get_zone_id)"

  local url="https://api.cloudflare.com/client/v4/zones/${zone_id}${endpoint}"
  local args=(
    -s -X "$method"
    -H "Authorization: Bearer $token"
    -H "Content-Type: application/json"
    "$url"
  )
  [[ -n "$body" ]] && args+=(-d "$body")

  local response
  response=$(curl "${args[@]}") || die "Cloudflare API request failed"
  echo "$response"
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

    # State bucket policy: deny non-SSL + restrict access to deployer + admin (MED-1)
    local caller_arn
    caller_arn=$(aws sts get-caller-identity --query Arn --output text --region "$region") \
      || die "Failed to get caller ARN"
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text --region "$region")
    local deployer_arn="arn:aws:iam::${account_id}:user/appserver-deployer"

    aws s3api put-bucket-policy \
      --bucket "$bucket" \
      --region "$region" \
      --policy "$(jq -n \
        --arg bucket "$bucket" \
        --arg caller "$caller_arn" \
        --arg deployer "$deployer_arn" \
        --arg account "$account_id" \
        '{
          Version: "2012-10-17",
          Statement: [
            {
              Sid: "DenyNonSSL",
              Effect: "Deny",
              Principal: "*",
              Action: "s3:*",
              Resource: [
                "arn:aws:s3:::\($bucket)",
                "arn:aws:s3:::\($bucket)/*"
              ],
              Condition: {
                Bool: { "aws:SecureTransport": "false" }
              }
            },
            {
              Sid: "RestrictStateAccess",
              Effect: "Deny",
              Principal: "*",
              Action: "s3:*",
              Resource: [
                "arn:aws:s3:::\($bucket)",
                "arn:aws:s3:::\($bucket)/*"
              ],
              Condition: {
                StringNotLike: {
                  "aws:PrincipalArn": [
                    $caller,
                    $deployer,
                    "arn:aws:iam::\($account):root"
                  ]
                }
              }
            }
          ]
        }')" || die "Failed to set bucket policy"

    aws s3api put-bucket-lifecycle-configuration \
      --bucket "$bucket" \
      --region "$region" \
      --lifecycle-configuration '{
        "Rules": [{
          "ID": "ExpireOldStateVersions",
          "Status": "Enabled",
          "Filter": {"Prefix": ""},
          "NoncurrentVersionExpiration": {"NoncurrentDays": 90}
        }]
      }' || echo "  WARNING: Failed to set lifecycle policy (non-fatal)"

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

  # Import orphaned artifacts bucket if it exists but isn't in state
  # (happens when a previous destroy deleted state but the bucket survived)
  local artifacts_bucket
  artifacts_bucket="$(get_artifacts_bucket)"
  if aws s3api head-bucket --bucket "$artifacts_bucket" --region "$region" 2>/dev/null \
     && ! terraform state show aws_s3_bucket.artifacts &>/dev/null; then
    echo "Importing existing artifacts bucket into state..."
    terraform import aws_s3_bucket.artifacts "$artifacts_bucket" 2>&1 | mask_account_ids
  fi

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
    terraform destroy -input=false -auto-approve \
      -var "force_destroy=true" 2>&1 | mask_account_ids
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

  # Detach deployer policies from calling user and delete them
  for name in "${deployer_policies[@]}"; do
    local arn="arn:aws:iam::${account_id}:policy/${name}"
    aws iam detach-user-policy --user-name "$caller_user" --policy-arn "$arn" 2>/dev/null || true
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
  local target="${1:-}"
  if [[ "$target" == "bootstrap" ]]; then
    ssm_run "tail -n 200 /var/log/appserver-bootstrap.log 2>/dev/null || echo 'No bootstrap log found at /var/log/appserver-bootstrap.log'" 60 || return 1
  elif [[ -n "$target" ]]; then
    [[ "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $target"
    ssm_run "cd /opt/appserver/apps/$target && docker compose logs --tail=100 2>&1" 60 || return 1
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
  " 120 || { echo "ERROR: Deploy failed on instance — check 'appserver logs $app'" >&2; return 1; }

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
  echo "  3. Register your first passkey (all users are peers — no admin tier in v1.43.0+)"
}

# Check Cloudflare IP ranges against traefik.yml trustedIPs.
# Missing ranges = Traefik silently strips X-Forwarded-For from those edge nodes,
# so Django sees Traefik's IP instead of the client. Rate limiting, logging, and
# IP-based security all break with no error signal.
# Returns: 0 = in sync, 1 = drift detected, 2 = fetch failed
check_cloudflare_ip_drift() {
  local traefik_yml="$CONFIG_DIR/traefik/traefik.yml"
  [ -f "$traefik_yml" ] || return 2

  local live_v4 live_v6 live configured
  live_v4=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null) || return 2
  live_v6=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" 2>/dev/null) || return 2
  live=$(printf '%s\n%s' "$live_v4" "$live_v6" | grep -v '^$' | sort)

  configured=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+|[0-9a-f:]+/[0-9]+' "$traefik_yml" \
      | grep -v '^127\.' | grep -v '^172\.16\.' | sort)

  CF_IP_MISSING=$(comm -23 <(echo "$live") <(echo "$configured"))
  CF_IP_EXTRA=$(comm -13 <(echo "$live") <(echo "$configured"))
  CF_IP_LIVE="$live"

  if [ -z "$CF_IP_MISSING" ] && [ -z "$CF_IP_EXTRA" ]; then
    return 0
  fi
  return 1
}

# Rewrite the trustedIPs block in traefik.yml with current Cloudflare ranges.
sync_cloudflare_ips() {
  local traefik_yml="$CONFIG_DIR/traefik/traefik.yml"
  local indent="        "
  local new_block=""
  new_block+="${indent}# Local: cloudflared systemd service connects via localhost/Docker bridge\n"
  new_block+="${indent}- \"127.0.0.0/8\"\n"
  new_block+="${indent}- \"172.16.0.0/12\"\n"
  new_block+="${indent}# Cloudflare public IP ranges (synced $(date +%Y-%m-%d))\n"
  new_block+="${indent}# https://www.cloudflare.com/ips-v4 / ips-v6\n"
  new_block+="${indent}# Audit: ./scripts/appserver.sh config check-ips\n"
  while IFS= read -r cidr; do
    [ -n "$cidr" ] && new_block+="${indent}- \"$cidr\"\n"
  done <<< "$CF_IP_LIVE"

  awk -v new_ips="$new_block" '
    /trustedIPs:/ { print; in_block=1; next }
    in_block && /^[[:space:]]*-/ { next }
    in_block && !/^[[:space:]]*-/ && !/^[[:space:]]*#/ { printf "%s", new_ips; in_block=0 }
    in_block && /^[[:space:]]*#/ { next }
    !in_block { print }
    END { if (in_block) printf "%s", new_ips }
  ' "$traefik_yml" > "${traefik_yml}.tmp" && mv "${traefik_yml}.tmp" "$traefik_yml"
}

cmd_config_check_ips() {
  echo "Checking Cloudflare IP ranges against traefik.yml..."
  check_cloudflare_ip_drift
  local rc=$?

  if [ "$rc" -eq 2 ]; then
    die "Could not fetch Cloudflare IP ranges (network error or traefik.yml missing)"
  fi

  if [ "$rc" -eq 0 ]; then
    echo "Cloudflare IP ranges are up to date."
    return 0
  fi

  # Drift detected — explain the impact
  if [ -n "$CF_IP_MISSING" ]; then
    echo "WARNING: New Cloudflare ranges missing from traefik.yml"
    echo "  Impact: Traefik strips X-Forwarded-For from these edge nodes."
    echo "  Result: Django sees wrong client IP — rate limiting and logging break silently."
    echo "$CF_IP_MISSING" | while read -r cidr; do echo "  + $cidr"; done
  fi
  if [ -n "$CF_IP_EXTRA" ]; then
    echo "Stale ranges (removed by Cloudflare):"
    echo "$CF_IP_EXTRA" | while read -r cidr; do echo "  - $cidr"; done
  fi

  if [ "${1:-}" = "--fix" ]; then
    echo ""
    sync_cloudflare_ips
    echo "Updated traefik.yml. Run 'appserver config push' to deploy."
  else
    echo ""
    echo "Fix with: ./scripts/appserver.sh config check-ips --fix"
  fi
}

cmd_config_push() {
  # Pre-flight: warn if Cloudflare IP ranges have drifted
  check_cloudflare_ip_drift
  local ip_rc=$?
  if [ "$ip_rc" -eq 1 ]; then
    echo "WARNING: Cloudflare IP ranges in traefik.yml are out of date."
    if [ -n "$CF_IP_MISSING" ]; then
      echo "  Missing ranges — X-Forwarded-For will be silently stripped for some edge nodes."
      echo "$CF_IP_MISSING" | while read -r cidr; do echo "    + $cidr"; done
    fi
    echo "  Run 'appserver config check-ips --fix' first, or proceed at your own risk."
    echo ""
    read -rp "Push anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
  fi

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

# --- Threat Analysis ---

REPORTS_DIR="$SCRIPT_DIR/../reports/threats"

# Collect app-layer security data from the instance via SSM.
# Gathers: cookie_admin audit events, nginx 4xx/5xx summary, container die/OOM
# events, and cloudflared warning lines — all within the given time window.
# Outputs a JSON object ready to be merged into the threat report.
_collect_app_security() {
  local duration_sec="$1"
  local app_script
  app_script=$(cat <<'APP_EOF'
set -e
CUTOFF_ISO=$(date -u -d "$DURATION_SEC seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u -v-"${DURATION_SEC}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Cookie security audit (last 200 events)
AUDIT='{"ok":false,"events":[]}'
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  AUDIT=$(docker exec cookie-web python manage.py cookie_admin audit --json --lines 200 2>/dev/null \
          || echo '{"ok":false,"events":[]}')
fi

# Nginx status code summary from cookie-web (last 2000 access log lines)
NGINX_5XX=0
NGINX_4XX=0
TOP_ERROR_PATHS=""
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  NGINX_LINES=$(docker exec cookie-web tail -2000 /var/log/nginx/access.log 2>/dev/null || echo "")
  if [[ -n "$NGINX_LINES" ]]; then
    NGINX_5XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^5[0-9]{2}$' || echo 0)
    NGINX_4XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^4[0-9]{2}$' || echo 0)
    TOP_ERROR_PATHS=$(echo "$NGINX_LINES" \
      | awk '$9 ~ /^[45][0-9]{2}$/ {print $7}' \
      | sort | uniq -c | sort -rn | head -10 \
      | awk '{printf "%s:%s,", $2, $1}' | sed 's/,$//' || echo "")
  fi
fi

# Docker container die/OOM events since cutoff.
# --until is required: without it docker events tails live events indefinitely,
# causing the subshell to hang when no historical events exist.
UNTIL_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTAINER_RESTARTS=$(docker events --since "$CUTOFF_ISO" --until "$UNTIL_ISO" \
  --filter type=container \
  --filter event=die \
  --filter event=oom \
  --format '{{.Time}} {{.Actor.Attributes.name}} {{.Action}} exit={{.Actor.Attributes.exitCode}}' \
  2>/dev/null | head -20 || echo "")

# cloudflared warnings since cutoff
TUNNEL_WARNINGS=$(journalctl -u cloudflared --since "$CUTOFF_ISO" \
  --no-pager -o short 2>/dev/null \
  | grep -iE "error|warn|failed|disconnect|reconn|retry" \
  | tail -10 || echo "")

# Emit structured JSON
jq -n \
  --arg audit_raw "$AUDIT" \
  --arg nginx_5xx "$NGINX_5XX" \
  --arg nginx_4xx "$NGINX_4XX" \
  --arg top_error_paths "$TOP_ERROR_PATHS" \
  --arg container_restarts "$CONTAINER_RESTARTS" \
  --arg tunnel_warnings "$TUNNEL_WARNINGS" \
  '{
    app_security: (
      ($audit_raw | fromjson? // {"ok":false,"events":[]}) |
      {
        audit_ok: (.ok // false),
        event_count: (.events // [] | length),
        recent_registrations: (.events // [] | map(select(.type == "registration")) | length),
        recent_logins: (.events // [] | map(select(.type == "passkey_login" or .type == "device_code_authorized")) | length),
        events_sample: (.events // [] | .[0:5])
      }
    ),
    app_errors: {
      nginx_5xx: ($nginx_5xx | tonumber? // 0),
      nginx_4xx: ($nginx_4xx | tonumber? // 0),
      top_error_paths: (
        if $top_error_paths == "" then []
        else ($top_error_paths | split(",") | map(select(length > 0))
          | map(split(":") | {path: .[0], count: (.[1] | tonumber? // 0)}))
        end
      )
    },
    container_events: {
      restarts: (if $container_restarts == ""
        then []
        else ($container_restarts | split("\n") | map(select(length > 0)))
        end)
    },
    tunnel_health: {
      warnings: (if $tunnel_warnings == ""
        then []
        else ($tunnel_warnings | split("\n") | map(select(length > 0)))
        end)
    }
  }'
APP_EOF
)
  app_script="DURATION_SEC=$duration_sec
$app_script"
  ssm_run "$app_script" 60 2>/dev/null || echo '{}'
}

# Compare yesterday's AWS spend against the day before to detect cost anomalies.
# Uses the Cost Explorer API (us-east-1 always). Returns JSON with anomaly field:
# "normal" | "elevated" (>$2/day) | "spike" (>1.5x previous day).
_check_cost_anomaly() {
  local today yesterday two_days_ago
  today=$(date +%Y-%m-%d)
  yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null \
           || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
  two_days_ago=$(date -d '2 days ago' +%Y-%m-%d 2>/dev/null \
              || date -v-2d +%Y-%m-%d 2>/dev/null || echo "")
  [[ -n "$yesterday" && -n "$two_days_ago" ]] \
    || { echo '{"available":false,"reason":"date calculation failed"}'; return; }

  local result
  result=$(aws ce get-cost-and-usage \
    --profile appserver \
    --time-period "Start=${two_days_ago},End=${today}" \
    --granularity DAILY \
    --metrics BlendedCost \
    --region us-east-1 \
    --output json 2>/dev/null) \
    || { echo '{"available":false,"reason":"API call failed"}'; return; }

  echo "$result" | jq '
    .ResultsByTime as $r |
    if ($r | length) >= 2 then
      (($r[-2].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $prev |
      (($r[-1].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $curr |
      {
        available: true,
        yesterday: $curr,
        day_before: $prev,
        currency: $r[-1].Total.BlendedCost.Unit,
        anomaly: (
          if $prev > 0.01 and $curr > ($prev * 1.5) then "spike"
          elif $curr > 2.0 then "elevated"
          else "normal"
          end
        )
      }
    else {"available":false,"reason":"insufficient data"}
    end
  ' 2>/dev/null || echo '{"available":false,"reason":"parse failed"}'
}

cmd_threats_analyze() {
  local since="24h"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:?--since requires a value}"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  # Validate --since format
  [[ "$since" =~ ^[0-9]+(h|d)$ ]] || die "Invalid --since format: $since (use e.g. 1h, 6h, 24h, 7d)"

  echo "Analyzing access logs (last $since)..."

  # Convert duration to seconds for jq time filtering
  local duration_sec
  local num="${since%[hd]}"
  local unit="${since: -1}"
  case "$unit" in
    h) duration_sec=$((num * 3600)) ;;
    d) duration_sec=$((num * 86400)) ;;
  esac

  # Build the on-instance analysis script
  local analysis_script
  analysis_script=$(cat <<'ANALYSIS_EOF'
set -e

ACCESS_LOG="/var/log/traefik/access.log"
if [[ ! -f "$ACCESS_LOG" ]] || [[ ! -s "$ACCESS_LOG" ]]; then
  echo '{"error":"No access log found or log is empty"}' >&2
  exit 1
fi

CUTOFF_EPOCH=$(($(date +%s) - DURATION_SEC))

# Scanner path patterns (one per line for grep -f)
SCANNER_PATHS=$(cat <<'PATHS'
wp-admin
wp-login
wp-content
wp-includes
xmlrpc.php
\.env
\.git
\.svn
\.htaccess
\.htpasswd
\.DS_Store
config\.yml
config\.json
composer\.json
package\.json
Dockerfile
phpmyadmin
adminer
/admin
cpanel
webmail
/shell
/cmd
/console
/terminal
cgi-bin
/solr
/actuator
/api/v1/pods
\.well-known/openid
/debug
/trace
/server-status
/server-info
/manager/html
/jenkins
/swagger
phpinfo
/telescope
PATHS
)

# Scanner user agent patterns
SCANNER_UAS="sqlmap|nikto|nmap|masscan|zgrab|nuclei|dirbuster|gobuster|ffuf|wfuzz|hydra|medusa|w3af|skipfish|arachni|acunetix|nessus|openvas|burpsuite"

# Main analysis with jq — filter by time window, aggregate per IP
jq -s --argjson cutoff "$CUTOFF_EPOCH" '
  # Parse entries and filter by time window
  [ .[] | select(
    (.StartUTC // "" | length > 0) and
    ((.StartUTC | split(".")[0] + "Z" | fromdateiso8601) >= $cutoff)
  ) ] |

  # Aggregate stats
  {
    log_entries_analyzed: length,
    unique_ips: ([.[].request_CF_Connecting_IP // .[].ClientHost] | unique | length),
    total_requests: length,
    per_ip: (
      group_by(.request_CF_Connecting_IP // .ClientHost) |
      map({
        ip: (.[0].request_CF_Connecting_IP // .[0].ClientHost),
        count: length,
        paths: [.[].RequestPath] | unique | .[0:10],
        user_agents: [.[].request_User_Agent // ""] | unique | .[0:5],
        status_codes: (group_by(.DownstreamStatus) | map({(.[0].DownstreamStatus | tostring): length}) | add),
        first_seen: ([.[].StartUTC] | sort | first),
        last_seen: ([.[].StartUTC] | sort | last),
        methods: ([.[].RequestMethod] | unique)
      }) |
      sort_by(-.count)
    )
  }
' "$ACCESS_LOG" 2>/dev/null || echo '{"error":"jq analysis failed"}'
ANALYSIS_EOF
)

  # Inject the duration variable
  analysis_script="DURATION_SEC=$duration_sec
$analysis_script"

  local raw_output
  raw_output=$(ssm_run "$analysis_script" 120) || {
    echo "ERROR: Failed to run analysis on instance" >&2
    return 2
  }

  # Check for error
  local error
  error=$(echo "$raw_output" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    echo "ERROR: $error" >&2
    return 2
  fi

  # Generate findings and recommendations locally
  local timestamp
  timestamp=$(date -u +"%Y%m%d-%H%M%S")
  local report_dir="$REPORTS_DIR/$timestamp"
  mkdir -p "$report_dir"

  # Process raw data into findings + recommendations
  local report
  report=$(echo "$raw_output" | jq --arg since "$since" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
    # Scanner path patterns
    def is_scanner_path:
      test("wp-admin|wp-login|wp-content|wp-includes|xmlrpc|\\.(env|git|svn|htaccess|htpasswd|DS_Store)|config\\.(yml|json)|composer\\.json|package\\.json|Dockerfile|phpmyadmin|adminer|/admin|cpanel|webmail|/shell|/cmd|/console|/terminal|cgi-bin|/solr|/actuator|/api/v1/pods|/debug|/trace|/server-status|/server-info|/manager/html|/jenkins|/swagger|phpinfo|/telescope"; "i");

    # Scanner user agent patterns
    def is_scanner_ua:
      test("sqlmap|nikto|nmap|masscan|zgrab|nuclei|dirbuster|gobuster|ffuf|wfuzz|hydra|medusa|w3af|skipfish|arachni|acunetix|nessus|openvas|burpsuite"; "i");

    # Traversal patterns
    def is_traversal:
      test("\\.\\.(/|%2[fF]|%252[fF])");

    # Determine categories for each IP
    .per_ip | map(
      . as $ip |
      {
        ip: .ip,
        count: .count,
        paths: .paths,
        user_agents: .user_agents,
        status_codes: .status_codes,
        first_seen: .first_seen,
        last_seen: .last_seen,
        categories: (
          [
            (if ([.paths[] | select(is_scanner_path)] | length) > 0 then "path_scan" else empty end),
            (if ([.user_agents[] | select(is_scanner_ua)] | length) > 0 then "scanner_ua" else empty end),
            (if ([.paths[] | select(is_traversal)] | length) > 0 then "traversal" else empty end),
            (if .count > 100 then "high_rate" else empty end),
            (if ((.status_codes // {}) | to_entries | map(select(.key | test("^(401|403)$"))) | map(.value) | add // 0) > 10
              and ([.paths[] | select(test("/api/auth|/login|/signin|/session"; "i"))] | length) > 0
              then "auth_brute_force" else empty end)
          ]
        ),
        error_ratio: (
          ((.status_codes // {}) | to_entries |
            { errors: (map(select(.key | test("^[45]"))) | map(.value) | add // 0),
              total: (map(.value) | add // 1) }) |
          (.errors / .total)
        )
      }
    ) |

    # Filter to only IPs with threat signals
    map(select(.categories | length > 0 or .error_ratio > 0.9)) |

    # Generate findings
    . as $threats |
    {
      timestamp: $ts,
      time_window: $since,
      log_entries_analyzed: (input.log_entries_analyzed // 0),
      unique_ips: (input.unique_ips // 0),
      total_requests: (input.total_requests // 0),
      status: (if ($threats | length) > 0 then "threats_detected" else "clean" end),
      findings: [
        $threats | to_entries[] |
        .value as $t | .key as $idx |
        {
          id: ("F-" + (($idx + 1) | tostring | if length < 3 then "0" * (3 - length) + . else . end)),
          category: ($t.categories[0] // "suspicious"),
          severity: (
            if ($t.categories | any(. == "traversal")) and ($t.error_ratio < 0.95) then "critical"
            elif ($t.categories | any(. == "auth_brute_force")) then "high"
            elif $t.count > 500 or ($t.categories | length) > 1 then "high"
            elif $t.count > 50 then "medium"
            elif $t.count > 10 then "low"
            else "info"
            end
          ),
          ip: $t.ip,
          count: $t.count,
          sample_paths: $t.paths[0:5],
          sample_ua: ($t.user_agents[0] // ""),
          first_seen: $t.first_seen,
          last_seen: $t.last_seen,
          status_codes: ($t.status_codes // {})
        }
      ] | sort_by(
        if .severity == "critical" then 0
        elif .severity == "high" then 1
        elif .severity == "medium" then 2
        elif .severity == "low" then 3
        else 4 end
      ),
      recommendations: [],
      cf_edge: null
    }
  ' - <<<"$raw_output" 2>/dev/null)

  # If jq processing failed, try a simpler approach
  if [[ -z "$report" ]] || [[ "$report" == "null" ]]; then
    report=$(echo "$raw_output" | jq --arg since "$since" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
      {
        timestamp: $ts,
        time_window: $since,
        log_entries_analyzed: .log_entries_analyzed,
        unique_ips: .unique_ips,
        total_requests: .total_requests,
        status: "clean",
        findings: [],
        recommendations: [],
        cf_edge: null
      }
    ')
  fi

  # Generate recommendations from findings
  report=$(echo "$report" | jq '
    .recommendations = [
      .findings[] |
      select(.severity == "critical" or .severity == "high" or
        (.severity == "medium" and .count > 100)) |
      {
        id: (.id | sub("^F-"; "R-")),
        action: (
          if .category == "traversal" then "block_ip"
          elif .category == "auth_brute_force" then "block_ip"
          elif .category == "scanner_ua" then "block_ip"
          elif .category == "path_scan" and .count > 100 then "block_ip"
          elif .category == "high_rate" then "monitor"
          else "investigate"
          end
        ),
        target: .ip,
        rationale: (
          "\(.category): \(.count) requests, " +
          (if (.status_codes | to_entries | map(select(.key | test("^[45]"))) | map(.value) | add // 0) as $errs |
              (.count) as $total |
              (($errs / (if $total == 0 then 1 else $total end)) * 100 | floor)
            then "\(.)% error responses"
            else "unknown error ratio"
          end) +
          ", \(.sample_ua)" +
          " (\(.id))"
        ),
        confidence: (
          if .severity == "critical" or .severity == "high" then "high"
          elif .severity == "medium" then "medium"
          else "low"
          end
        ),
        finding_ids: [.id]
      }
    ]
  ')

  # Attempt CF edge data enrichment (optional — requires Analytics:Read permission)
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    local cf_edge_response
    local zone_id
    zone_id="$(get_zone_id 2>/dev/null)" || zone_id=""
    if [[ -n "$zone_id" ]]; then
      local since_ts
      since_ts=$(date -u -d "$duration_sec seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${duration_sec}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      local until_ts
      until_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      if [[ -n "$since_ts" ]]; then
        local gql_query
        gql_query=$(jq -n --arg zone "$zone_id" --arg since "$since_ts" --arg until "$until_ts" '{
          query: "query { viewer { zones(filter: {zoneTag: $zoneTag}) { firewallEventsAdaptive(filter: {datetime_gt: $since, datetime_lt: $until}, limit: 100, orderBy: [datetime_DESC]) { action clientIP datetime ruleId source } } } }",
          variables: { zoneTag: $zone, since: $since, until: $until }
        }')

        cf_edge_response=$(curl -s -X POST \
          "https://api.cloudflare.com/client/v4/graphql" \
          -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$gql_query" 2>/dev/null) || cf_edge_response=""

        # Check if we got a valid response (not 403)
        local cf_errors
        cf_errors=$(echo "$cf_edge_response" | jq -r '.errors[]?.message // empty' 2>/dev/null)
        if [[ -z "$cf_errors" ]] && echo "$cf_edge_response" | jq -e '.data.viewer.zones[0]' &>/dev/null; then
          local cf_edge
          cf_edge=$(echo "$cf_edge_response" | jq '{
            available: true,
            waf_blocks: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.action == "block")] | length),
            rate_limit_triggers: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.source == "rateLimit")] | length),
            top_blocked_ips: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.action == "block") | .clientIP] | group_by(.) | map({ip: .[0], count: length}) | sort_by(-.count) | .[0:5])
          }')
          report=$(echo "$report" | jq --argjson edge "$cf_edge" '.cf_edge = $edge')
        fi
      fi
    fi
  fi

  # Collect app security data (cookie audit + nginx + containers + tunnel)
  echo "Collecting app security data..."
  local app_data
  app_data=$(_collect_app_security "$duration_sec")
  if echo "$app_data" | jq -e '.app_security' &>/dev/null; then
    report=$(echo "$report" | jq --argjson app "$app_data" '. + $app')
  fi

  # Cost anomaly check (local AWS CE call)
  echo "Checking AWS cost..."
  local cost_data
  cost_data=$(_check_cost_anomaly)
  report=$(echo "$report" | jq --argjson cost "$cost_data" '.cost_anomaly = $cost')

  # Write report.json
  echo "$report" | jq '.' > "$report_dir/report.json"

  # Generate SUMMARY.md
  local finding_count rec_count report_status total_requests unique_ips
  finding_count=$(echo "$report" | jq '.findings | length')
  rec_count=$(echo "$report" | jq '.recommendations | length')
  report_status=$(echo "$report" | jq -r '.status')
  total_requests=$(echo "$report" | jq '.total_requests')
  unique_ips=$(echo "$report" | jq '.unique_ips')

  {
    echo "# Threat Report: $(date -u +"%Y-%m-%d %H:%M")"
    echo
    echo "**Window**: Last $since | **Requests**: $total_requests | **Unique IPs**: $unique_ips | **Status**: $(echo "$report_status" | tr '_' ' ' | tr '[:lower:]' '[:upper:]')"
    echo

    if [[ "$finding_count" -gt 0 ]]; then
      echo "## Findings ($finding_count threats)"
      echo
      echo "$report" | jq -r '.findings[] |
        "### [\(.severity | ascii_upcase)] \(.id): \(.category | gsub("_"; " ")) from \(.ip)\n" +
        "- **Requests**: \(.count) (" + (.status_codes | to_entries | map("\(.key): \(.value)") | join(", ")) + ")\n" +
        "- **Paths**: " + (.sample_paths | join(", ")) + "\n" +
        "- **User Agent**: \(.sample_ua)\n" +
        "- **Window**: \(.first_seen // "?") — \(.last_seen // "?")\n"'
    else
      echo "## Findings"
      echo
      echo "_No threats detected._"
    fi

    echo
    echo "## Recommendations"
    echo

    if [[ "$rec_count" -gt 0 ]]; then
      echo "| ID | Action | Target | Confidence | Rationale |"
      echo "|----|--------|--------|------------|-----------|"
      echo "$report" | jq -r '.recommendations[] | "| \(.id) | \(.action) | \(.target) | \(.confidence) | \(.rationale) |"'
    else
      echo "_No recommendations._"
    fi

    # CF Edge section if data available
    local cf_available
    cf_available=$(echo "$report" | jq -r '.cf_edge.available // false')
    if [[ "$cf_available" == "true" ]]; then
      echo
      echo "## Cloudflare Edge"
      echo
      echo "_Traffic blocked before reaching the server:_"
      echo
      echo "- **WAF Blocks**: $(echo "$report" | jq '.cf_edge.waf_blocks')"
      echo "- **Rate Limit Triggers**: $(echo "$report" | jq '.cf_edge.rate_limit_triggers')"
      local top_blocked
      top_blocked=$(echo "$report" | jq -r '.cf_edge.top_blocked_ips[]? | "- \(.ip) (\(.count) blocks)"')
      if [[ -n "$top_blocked" ]]; then
        echo
        echo "**Top Blocked IPs:**"
        echo "$top_blocked"
      fi
    fi

    # App Security section
    local app_audit_ok registrations logins nginx_5xx nginx_4xx container_count tunnel_count
    app_audit_ok=$(echo "$report" | jq -r '.app_security.audit_ok // false')
    registrations=$(echo "$report" | jq -r '.app_security.recent_registrations // "?"')
    logins=$(echo "$report" | jq -r '.app_security.recent_logins // "?"')
    nginx_5xx=$(echo "$report" | jq -r '.app_errors.nginx_5xx // 0')
    nginx_4xx=$(echo "$report" | jq -r '.app_errors.nginx_4xx // 0')
    container_count=$(echo "$report" | jq '.container_events.restarts | length // 0')
    tunnel_count=$(echo "$report" | jq '.tunnel_health.warnings | length // 0')

    if [[ "$app_audit_ok" == "true" ]] || [[ "$nginx_5xx" -gt 0 ]] || [[ "$nginx_4xx" -gt 0 ]]; then
      echo
      echo "## App Security"
      echo
      echo "- **Registrations (window)**: $registrations"
      echo "- **Auth events (window)**: $logins"
      echo "- **App 5xx errors** (last 2000 nginx lines): $nginx_5xx"
      echo "- **App 4xx errors** (last 2000 nginx lines): $nginx_4xx"
      if [[ "$nginx_5xx" -gt 10 ]]; then
        echo
        echo "⚠️ **Elevated 5xx count** — check Cookie logs"
        echo
        echo "$report" | jq -r '.app_errors.top_error_paths[]? | "  \(.path) (\(.count))"' | head -5
      fi
    fi

    if [[ "$container_count" -gt 0 ]]; then
      echo
      echo "## Container Events"
      echo
      echo "$report" | jq -r '.container_events.restarts[]?' | head -10
    fi

    if [[ "$tunnel_count" -gt 0 ]]; then
      echo
      echo "## Tunnel Warnings"
      echo
      echo "$report" | jq -r '.tunnel_health.warnings[]?' | head -5
    fi

    # Cost check section
    local cost_available cost_anomaly cost_yesterday cost_day_before cost_currency
    cost_available=$(echo "$report" | jq -r '.cost_anomaly.available // false')
    cost_anomaly=$(echo "$report" | jq -r '.cost_anomaly.anomaly // "unknown"')
    if [[ "$cost_available" == "true" ]]; then
      cost_yesterday=$(echo "$report" | jq -r '.cost_anomaly.yesterday')
      cost_day_before=$(echo "$report" | jq -r '.cost_anomaly.day_before')
      cost_currency=$(echo "$report" | jq -r '.cost_anomaly.currency')
      echo
      echo "## Cost Check"
      echo
      echo "- **Yesterday**: ${cost_yesterday} ${cost_currency}"
      echo "- **Day before**: ${cost_day_before} ${cost_currency}"
      echo "- **Status**: ${cost_anomaly}"
      if [[ "$cost_anomaly" == "spike" ]]; then
        echo
        echo "⚠️ **Cost spike detected** — investigate for unauthorized resource usage"
      fi
    fi

    echo
    echo "## Actions Taken"
    echo
    echo "_No actions taken yet. Use \`appserver.sh threats block <ip>\` or the threat-ops skill to enact recommendations._"
  } > "$report_dir/SUMMARY.md"

  # Initialize empty actions.json
  echo "[]" > "$report_dir/actions.json"

  # Print summary to stdout
  echo
  cat "$report_dir/SUMMARY.md"
  echo
  echo "Report saved to: $report_dir/"

  # Exit code based on status
  if [[ "$report_status" == "threats_detected" ]]; then
    return 1
  fi
  return 0
}

cmd_threats_block() {
  local ip="" note="threat-ops: blocked via CLI"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:?--note requires a value}"; shift 2 ;;
      -*) die "Unknown flag: $1" ;;
      *) ip="$1"; shift ;;
    esac
  done

  [[ -n "$ip" ]] || die "Usage: appserver threats block <ip> [--note <reason>]"

  # Validate IP format (IPv4 or IPv6)
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    die "Invalid IP format: $ip"
  fi

  echo "Blocking $ip..."
  local body
  body=$(jq -n --arg ip "$ip" --arg note "$note" '{
    mode: "block",
    configuration: { target: "ip", value: $ip },
    notes: $note
  }')

  local response
  response=$(cf_api POST "/firewall/access_rules/rules" "$body")

  local success
  success=$(echo "$response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    # Check if already blocked
    local errors
    errors=$(echo "$response" | jq -r '.errors[]?.message // empty')
    if echo "$errors" | grep -qi "already exists"; then
      echo "IP $ip is already blocked."
      return 2
    fi
    echo "ERROR: Failed to block $ip" >&2
    echo "$response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result.id')
  echo "Blocked $ip (rule ID: $rule_id)"

  # Track action in latest report's actions.json
  _track_action "block_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_unblock() {
  local ip="${1:?Usage: appserver threats unblock <ip>}"

  echo "Looking up block rule for $ip..."
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=block&configuration.value=$ip")

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result[]? | select(.configuration.value == "'"$ip"'") | .id' | head -1)

  if [[ -z "$rule_id" ]]; then
    echo "ERROR: No block rule found for $ip" >&2
    return 1
  fi

  local del_response
  del_response=$(cf_api DELETE "/firewall/access_rules/rules/$rule_id")

  local success
  success=$(echo "$del_response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    echo "ERROR: Failed to unblock $ip" >&2
    echo "$del_response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  echo "Unblocked $ip (removed rule $rule_id)"
  _track_action "unblock_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_blocked() {
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=block&per_page=50")

  local count
  count=$(echo "$response" | jq '.result | length')

  if [[ "$count" -eq 0 ]]; then
    echo "No IPs currently blocked."
    return 0
  fi

  echo "Blocked IPs ($count):"
  echo
  printf "%-18s %-40s %-22s %s\n" "IP" "Note" "Created" "Rule ID"
  printf "%-18s %-40s %-22s %s\n" "--" "----" "-------" "-------"
  echo "$response" | jq -r '.result[] | [.configuration.value, .notes, .created_on, .id] | @tsv' |
    while IFS=$'\t' read -r ip note created rule_id; do
      printf "%-18s %-40s %-22s %s\n" "$ip" "${note:0:38}" "${created:0:19}" "$rule_id"
    done
}

cmd_threats_allow() {
  # Create a Cloudflare IP Access Rule of mode "whitelist" so the caller IP
  # bypasses WAF challenges and rate limits — primarily for pentest sessions.
  # With no IP argument, auto-detects the caller's public IP via ifconfig.me.
  local ip="" note="pentest: allowlist via CLI"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:?--note requires a value}"; shift 2 ;;
      -*) die "Unknown flag: $1" ;;
      *) ip="$1"; shift ;;
    esac
  done

  if [[ -z "$ip" ]]; then
    echo "No IP specified — detecting public IP..."
    ip=$(curl -fsS https://ifconfig.me 2>/dev/null) \
      || die "Failed to detect public IP. Provide it explicitly: appserver threats allow <ip>"
    echo "Detected public IP: $ip"
  fi

  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    die "Invalid IP format: $ip"
  fi

  echo "Allowlisting $ip..."
  local body
  body=$(jq -n --arg ip "$ip" --arg note "$note" '{
    mode: "whitelist",
    configuration: { target: "ip", value: $ip },
    notes: $note
  }')

  local response
  response=$(cf_api POST "/firewall/access_rules/rules" "$body")

  local success
  success=$(echo "$response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    local errors
    errors=$(echo "$response" | jq -r '.errors[]?.message // empty')
    if echo "$errors" | grep -qi "already exists"; then
      echo "IP $ip is already allowlisted."
      return 2
    fi
    echo "ERROR: Failed to allowlist $ip" >&2
    echo "$response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result.id')
  echo "Allowlisted $ip (rule ID: $rule_id)"
  echo "Reminder: run 'appserver threats unallow $ip' once the pentest scan completes."

  _track_action "allow_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_unallow() {
  local ip="${1:?Usage: appserver threats unallow <ip>}"

  echo "Looking up allow rule for $ip..."
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=whitelist&configuration.value=$ip")

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result[]? | select(.configuration.value == "'"$ip"'") | .id' | head -1)

  if [[ -z "$rule_id" ]]; then
    echo "ERROR: No allow rule found for $ip" >&2
    return 1
  fi

  local del_response
  del_response=$(cf_api DELETE "/firewall/access_rules/rules/$rule_id")

  local success
  success=$(echo "$del_response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    echo "ERROR: Failed to remove allow rule for $ip" >&2
    echo "$del_response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  echo "Removed allow rule for $ip (removed rule $rule_id)"
  _track_action "unallow_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_allowed() {
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=whitelist&per_page=50")

  local count
  count=$(echo "$response" | jq '.result | length')

  if [[ "$count" -eq 0 ]]; then
    echo "No IPs currently allowlisted."
    return 0
  fi

  echo "Allowlisted IPs ($count):"
  echo
  printf "%-18s %-40s %-22s %s\n" "IP" "Note" "Created" "Rule ID"
  printf "%-18s %-40s %-22s %s\n" "--" "----" "-------" "-------"
  echo "$response" | jq -r '.result[] | [.configuration.value, .notes, .created_on, .id] | @tsv' |
    while IFS=$'\t' read -r ip note created rule_id; do
      printf "%-18s %-40s %-22s %s\n" "$ip" "${note:0:38}" "${created:0:19}" "$rule_id"
    done
}

cmd_threats_list() {
  if [[ ! -d "$REPORTS_DIR" ]]; then
    echo "No threat reports found."
    return 0
  fi

  local dirs
  dirs=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

  if [[ -z "$dirs" ]]; then
    echo "No threat reports found."
    return 0
  fi

  echo "Threat Reports:"
  echo
  printf "%-20s %-20s %-10s %s\n" "Timestamp" "Status" "Findings" "Recommendations"
  printf "%-20s %-20s %-10s %s\n" "---------" "------" "--------" "---------------"

  while IFS= read -r dir; do
    local ts
    ts=$(basename "$dir")
    if [[ -f "$dir/report.json" ]]; then
      local status finding_count rec_count
      status=$(jq -r '.status // "unknown"' "$dir/report.json")
      finding_count=$(jq '.findings | length' "$dir/report.json")
      rec_count=$(jq '.recommendations | length' "$dir/report.json")
      printf "%-20s %-20s %-10s %s\n" "$ts" "$status" "$finding_count" "$rec_count"
    else
      printf "%-20s %-20s %-10s %s\n" "$ts" "(no report.json)" "-" "-"
    fi
  done <<< "$dirs"
}

cmd_threats_report() {
  local ts="${1:-}"

  if [[ -z "$ts" ]]; then
    # Find latest
    if [[ ! -d "$REPORTS_DIR" ]]; then
      echo "No threat reports found."
      return 1
    fi
    local latest
    latest=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
    if [[ -z "$latest" ]]; then
      echo "No threat reports found."
      return 1
    fi
    ts=$(basename "$latest")
  fi

  local report_dir="$REPORTS_DIR/$ts"
  if [[ ! -d "$report_dir" ]]; then
    echo "Report not found: $ts"
    return 1
  fi

  if [[ -f "$report_dir/SUMMARY.md" ]]; then
    cat "$report_dir/SUMMARY.md"
  else
    echo "No SUMMARY.md in $report_dir"
    return 1
  fi

  # Show actions if any
  if [[ -f "$report_dir/actions.json" ]]; then
    local action_count
    action_count=$(jq 'length' "$report_dir/actions.json")
    if [[ "$action_count" -gt 0 ]]; then
      echo
      echo "## Actions Log ($action_count)"
      echo
      jq -r '.[] | "- [\(.timestamp)] \(.action_type) \(.target) → \(.result)"' "$report_dir/actions.json"
    fi
  fi
}

# Track a block/unblock action in the latest report's actions.json
_track_action() {
  local action_type="$1" target="$2" cf_rule_id="$3" result="$4" error="$5"

  # Find latest report dir
  local latest_dir=""
  if [[ -d "$REPORTS_DIR" ]]; then
    latest_dir=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
  fi

  if [[ -z "$latest_dir" ]]; then
    return 0  # No report to track against
  fi

  local actions_file="$latest_dir/actions.json"
  [[ -f "$actions_file" ]] || echo "[]" > "$actions_file"

  local action
  action=$(jq -n \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg at "$action_type" \
    --arg tgt "$target" \
    --arg rid "$cf_rule_id" \
    --arg res "$result" \
    --arg err "$error" \
    '{
      timestamp: $ts,
      recommendation_id: null,
      action_type: $at,
      target: $tgt,
      cf_rule_id: $rid,
      result: $res,
      error: (if $err == "" then null else $err end)
    }')

  local updated
  updated=$(jq --argjson action "$action" '. += [$action]' "$actions_file")
  echo "$updated" > "$actions_file"
}

cmd_threats() {
  case "${1:-}" in
    report)   shift; cmd_threats_report "$@" ;;
    list)     cmd_threats_list ;;
    block)    shift; cmd_threats_block "$@" ;;
    unblock)  shift; cmd_threats_unblock "$@" ;;
    blocked)  cmd_threats_blocked ;;
    allow)    shift; cmd_threats_allow "$@" ;;
    unallow)  shift; cmd_threats_unallow "$@" ;;
    allowed)  cmd_threats_allowed ;;
    ""|--*)   cmd_threats_analyze "$@" ;;
    *)        echo "Usage: appserver threats [--since <duration>] | report [<timestamp>] | list | block <ip> | unblock <ip> | blocked | allow [<ip>] | unallow <ip> | allowed" ;;
  esac
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

  read -rp "Base domain (e.g. matthewdeaves.com): " domain
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

  read -rp "Admin email [matt@matthewdeaves.com]: " email
  email="${email:-matt@matthewdeaves.com}"
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
  git-crypt lock
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
cmd_users() {
  local out
  out=$(ssm_run "docker exec cookie-web python manage.py cookie_admin list-users --json 2>/dev/null" 30) \
    || { echo "Could not reach Cookie. Is the instance running?" >&2; return 1; }

  if ! echo "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "ERROR: cookie_admin list-users failed" >&2
    echo "$out" >&2
    return 1
  fi

  local count
  count=$(echo "$out" | jq '.users | length')
  echo "Cookie users ($count):"
  echo
  printf "%-16s %-8s %-10s %-10s %-12s %s\n" "Username" "User ID" "Passkeys" "Active" "Unlimited" "Joined"
  printf "%-16s %-8s %-10s %-10s %-12s %s\n" "--------" "-------" "--------" "------" "---------" "------"
  echo "$out" | jq -r '.users[] | [.username, .user_id, .passkeys, .is_active, .unlimited_ai, .date_joined] | @tsv' \
    | while IFS=$'\t' read -r username user_id passkeys active unlimited joined; do
        printf "%-16s %-8s %-10s %-10s %-12s %s\n" "$username" "$user_id" "$passkeys" "$active" "$unlimited" "$joined"
      done
}

# Top-level shortcut: unified health summary across instance, containers, Cookie,
# and the latest threat report. Designed for "is everything OK?" checks.
cmd_health() {
  echo "=== Instance ==="
  local instance_id region instance_state
  instance_id="$(get_instance_id)" || { echo "instance: unknown (terraform output unavailable)"; echo; }
  region="$(get_region)"
  if [[ -n "$instance_id" ]]; then
    instance_state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null) \
      || instance_state="unknown"
    echo "state: $instance_state"
  fi
  echo

  echo "=== Containers ==="
  ssm_run "docker ps --format 'table {{.Names}}\t{{.Status}}'" 30 2>/dev/null \
    || echo "could not reach instance"
  echo

  echo "=== Cookie ==="
  local cookie_out
  cookie_out=$(ssm_run "docker exec cookie-web python manage.py cookie_admin status --json 2>/dev/null && echo --- && docker ps --filter name=cookie-web --format '{{.Image}}' | sed 's/.*://'" 30 2>/dev/null) || cookie_out=""

  if [[ -n "$cookie_out" ]]; then
    local status_json version
    status_json=$(echo "$cookie_out" | sed -n '1,/^---$/p' | sed '$d')
    version=$(echo "$cookie_out" | sed -n '/^---$/,$p' | sed '1d' | head -1)

    local ok db users passkeys auth_mode
    ok=$(echo "$status_json" | jq -r '.ok // false' 2>/dev/null)
    db=$(echo "$status_json" | jq -r '.database // "?"' 2>/dev/null)
    users=$(echo "$status_json" | jq -r '.users.total // 0' 2>/dev/null)
    passkeys=$(echo "$status_json" | jq -r '.passkeys // 0' 2>/dev/null)
    auth_mode=$(echo "$status_json" | jq -r '.auth_mode // "?"' 2>/dev/null)

    echo "version:    $version"
    echo "status:     $([ "$ok" = "true" ] && echo "ok" || echo "DEGRADED")"
    echo "database:   $db"
    echo "auth mode:  $auth_mode"
    echo "users:      $users (passkeys: $passkeys)"
  else
    echo "could not reach Cookie"
  fi
  echo

  echo "=== Latest threat report ==="
  local reports_dir="$SCRIPT_DIR/../reports/threats"
  if [[ -d "$reports_dir" ]]; then
    local latest
    latest=$(find "$reports_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest" && -f "$reports_dir/$latest/report.json" ]]; then
      local rstatus rfindings rrecs rtime
      rstatus=$(jq -r '.status' "$reports_dir/$latest/report.json")
      rfindings=$(jq '.findings | length' "$reports_dir/$latest/report.json")
      rrecs=$(jq '.recommendations | length' "$reports_dir/$latest/report.json")
      rtime=$(jq -r '.timestamp' "$reports_dir/$latest/report.json")
      echo "timestamp:       $rtime"
      echo "status:          $rstatus"
      echo "findings:        $rfindings"
      echo "recommendations: $rrecs"
    else
      echo "no reports yet — run 'appserver threats' to generate one"
    fi
  else
    echo "no reports yet — run 'appserver threats' to generate one"
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
  health)   cmd_health ;;
  users)    cmd_users ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  ssh)      cmd_ssh ;;
  logs)     cmd_logs "${2:-}" ;;
  spend)    cmd_spend ;;
  threats)  shift; cmd_threats "$@" ;;
  setup)    shift; cmd_setup "$@" ;;
  config)
    case "${2:-}" in
      push) cmd_config_push ;;
      check-ips) cmd_config_check_ips "${3:-}" ;;
      *)    echo "Usage: appserver config {push|check-ips [--fix]}" ;;
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
