#!/usr/bin/env bash
# Single SSM call that returns cookie_admin status + running version + user list.
# Run from the appserver repo root.
#
# Usage: ./quick-health.sh
#
# Output: JSON with keys: status, version, users
# Exit 0 = healthy, exit 1 = degraded or unreachable

set -euo pipefail
cd "$(dirname "$0")/../../../.." 2>/dev/null || true

REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null \
  | sed 's/.*= *"\(.*\)"/\1/' || echo "eu-west-2")
INSTANCE_ID=$(aws ec2 describe-instances --profile appserver \
  --filters "Name=tag:Name,Values=appserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] \
  || { echo '{"error":"instance not found or not running"}'; exit 1; }

CMD='
STATUS=$(docker exec cookie-web python manage.py cookie_admin status --json 2>/dev/null \
         || echo "{\"ok\":false}")
VERSION=$(docker ps --filter name=cookie-web --format "{{.Image}}" 2>/dev/null \
          | sed "s/.*://" || echo "unknown")
USERS=$(docker exec cookie-web python manage.py cookie_admin list-users --json 2>/dev/null \
        || echo "{\"ok\":false,\"users\":[]}")
jq -n --argjson status "$STATUS" --arg version "$VERSION" --argjson users "$USERS" \
  "{status: \$status, version: \$version, users: \$users}"
'

COMMAND_ID=$(aws ssm send-command --profile appserver \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(printf '{"commands":[%s]}' "$(echo "$CMD" | jq -Rs .)")" \
  --query "Command.CommandId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$COMMAND_ID" ]] || { echo '{"error":"send-command failed"}'; exit 1; }

sleep 8

OUTPUT=$(aws ssm get-command-invocation --profile appserver \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text --region "$REGION" 2>/dev/null)

echo "$OUTPUT"

# Exit 1 if not healthy
echo "$OUTPUT" | jq -e '.status.ok == true and .status.database == "ok"' &>/dev/null || exit 1
