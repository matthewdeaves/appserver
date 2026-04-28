#!/usr/bin/env bash
# Check Cookie's supercronic health: process running, crontab contents,
# and recent cron output from docker logs.
# Run from the appserver repo root.
#
# Usage: ./check-crons.sh
#
# Output: human-readable summary of cron health
# Exit 0 = healthy (supercronic running), exit 1 = supercronic not running

set -euo pipefail
cd "$(dirname "$0")/../../../.." 2>/dev/null || true

REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null \
  | sed 's/.*= *"\(.*\)"/\1/' || echo "eu-west-2")
INSTANCE_ID=$(aws ec2 describe-instances --profile appserver \
  --filters "Name=tag:Name,Values=appserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] \
  || { echo "ERROR: instance not found or not running"; exit 1; }

CMD='
echo "=== supercronic process ==="
docker exec cookie-web pgrep -a supercronic 2>/dev/null || echo "(not running)"
echo
echo "=== crontab (/app/crontab) ==="
docker exec cookie-web cat /app/crontab 2>/dev/null || echo "(not found)"
echo
echo "=== recent cron output (last 2h) ==="
docker logs cookie-web --since 2h 2>&1 | grep -iE "cleanup|cron|supercronic" | tail -20 || echo "(no output)"
'

COMMAND_ID=$(aws ssm send-command --profile appserver \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(printf '{"commands":[%s]}' "$(echo "$CMD" | jq -Rs .)")" \
  --query "Command.CommandId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$COMMAND_ID" ]] || { echo "ERROR: send-command failed"; exit 1; }

sleep 6

aws ssm get-command-invocation --profile appserver \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text --region "$REGION" 2>/dev/null

# Check if supercronic is running (output contains a PID line)
OUTPUT=$(aws ssm get-command-invocation --profile appserver \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text --region "$REGION" 2>/dev/null)
echo "$OUTPUT" | grep -q "^[0-9]" || exit 1
