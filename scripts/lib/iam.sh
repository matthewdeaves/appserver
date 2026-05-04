# shellcheck shell=bash
# scripts/lib/iam.sh — IAM bootstrap for the deployer user, deployer
# policies, and the state bucket. Used by `appserver.sh init` only;
# all routine ops go through assumed roles, not these helpers.
#
# Sourced by appserver.sh. Relies on die(), get_region(), get_state_bucket()
# from the parent shell.

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
  # Phase 5 cutover: the deployer USER now holds ONLY AppserverDeployerAssumeRoles.
  # The three legacy policies (compute / iam-ssm / monitoring-storage) are
  # still managed here so terraform-side resources (the deploy role) and the
  # admin/caller user can attach them, but they no longer attach to the
  # deployer user. A leaked access key is now reduced to MFA-gated
  # sts:AssumeRole on the three operator roles — useless without MFA.
  local policy_names=(
    "AppserverDeployerCompute"
    "AppserverDeployerIamSsm"
    "AppserverDeployerMonitoringStorage"
    "AppserverDeployerAssumeRoles"
  )
  local policy_files=(
    "$policy_dir/compute.json"
    "$policy_dir/iam-ssm.json"
    "$policy_dir/monitoring-storage.json"
    "$policy_dir/assume-roles.json"
  )

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

  # Phase 5: the deployer USER attaches ONLY the AssumeRoles policy.
  # Detach the legacy three from the user if a previous phase attached
  # them (idempotent — phase 1-4 installs leave them in place; phase 5
  # cleans them up on the next `init` run).
  local legacy_policy_names=(
    "AppserverDeployerCompute"
    "AppserverDeployerIamSsm"
    "AppserverDeployerMonitoringStorage"
  )
  attach_iam_policy "$deployer_user" "AppserverDeployerAssumeRoles" "$account_id"
  for name in "${legacy_policy_names[@]}"; do
    if aws iam list-attached-user-policies --user-name "$deployer_user" \
        --query "AttachedPolicies[?PolicyName=='$name']" --output text 2>/dev/null \
        | grep -q "$name"; then
      aws iam detach-user-policy --user-name "$deployer_user" \
        --policy-arn "arn:aws:iam::${account_id}:policy/${name}" 2>/dev/null \
        && echo "  Policy attachment .... detached ($name -> $deployer_user, phase-5 cutover)"
    fi
  done

  # The calling user (admin) still gets the three legacy policies attached
  # for emergency direct-deployer access without going through MFA.
  for name in "${legacy_policy_names[@]}"; do
    attach_iam_policy "$caller_user" "$name" "$account_id"
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

# Build the state-bucket policy. Idempotent — applied on every init run so
# that adding new operator roles (or changing the caller) automatically
# re-grants access. Allowlists: caller (admin), deployer USER, the three
# operator-role STS sessions, root.
state_bucket_policy_json() {
  local bucket="$1" caller="$2" account="$3"
  jq -n \
    --arg bucket "$bucket" \
    --arg caller "$caller" \
    --arg account "$account" \
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
          Condition: { Bool: { "aws:SecureTransport": "false" } }
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
                "arn:aws:iam::\($account):user/appserver-deployer",
                "arn:aws:iam::\($account):role/appserver-readonly-role",
                "arn:aws:iam::\($account):role/appserver-cookie-ops-role",
                "arn:aws:iam::\($account):role/appserver-deploy-role",
                "arn:aws:iam::\($account):root"
              ]
            }
          }
        }
      ]
    }'
}

ensure_state_backend() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  local caller_arn account_id
  caller_arn=$(aws sts get-caller-identity --query Arn --output text --region "$region") \
    || die "Failed to get caller ARN"
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region")

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

  # Always (re)apply the bucket policy so that adding a new operator role
  # to the allowlist takes effect on the next init run.
  aws s3api put-bucket-policy \
    --bucket "$bucket" \
    --region "$region" \
    --policy "$(state_bucket_policy_json "$bucket" "$caller_arn" "$account_id")" \
    || die "Failed to set bucket policy"
  echo "  Bucket policy ........ applied (allowlist: caller + deployer + 3 operator roles + root)"
}
