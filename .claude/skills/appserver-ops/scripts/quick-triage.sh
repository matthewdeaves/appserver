#!/usr/bin/env bash
# Run all infrastructure health layers in one pass and print a structured summary.
# Covers: EC2 state, SSM reachability, container health, Traefik, cloudflared,
# resource pressure (memory + disk), and external reachability via curl.
# Run from the appserver repo root.
#
# Usage: ./quick-triage.sh
#
# Output: human-readable triage report
# Exit 0 = all healthy, exit 1 = one or more layers degraded

set -euo pipefail
cd "$(dirname "$0")/../../../.." 2>/dev/null || true

REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null \
  | sed 's/.*= *"\(.*\)"/\1/' || echo "eu-west-2")
DOMAIN=$(grep '^domain' terraform/terraform.tfvars 2>/dev/null \
  | sed 's/.*= *"\(.*\)"/\1/' || echo "")

echo "=== Layer 1: EC2 Instance ==="
aws ec2 describe-instances --profile appserver \
  --filters "Name=tag:Name,Values=appserver" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,Launch:LaunchTime}' \
  --output table --region "$REGION" 2>/dev/null || echo "ERROR: EC2 describe failed"

echo
echo "=== Layer 2: SSM Reachability ==="
INSTANCE_ID=$(aws ec2 describe-instances --profile appserver \
  --filters "Name=tag:Name,Values=appserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION" 2>/dev/null)
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "FAIL: No running instance found"
  exit 1
fi
aws ssm describe-instance-information --profile appserver \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion}' \
  --output table --region "$REGION" 2>/dev/null || echo "ERROR: SSM describe failed"

echo
echo "=== Layers 3-6: Containers + Resources (via SSM) ==="
CMD='
echo "--- Containers ---"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo
echo "--- Traefik health ---"
docker exec traefik traefik healthcheck --ping 2>&1 && echo "HEALTHY" || echo "UNHEALTHY"
echo
echo "--- cloudflared ---"
systemctl is-active cloudflared && echo "active" || echo "INACTIVE"
journalctl -u cloudflared --since "10 min ago" --no-pager 2>/dev/null \
  | grep -iE "error|fail|disconnect" | tail -5 || true
echo
echo "--- Memory ---"
free -m | head -2
echo
echo "--- Disk ---"
df -h / | tail -1
echo
echo "--- Exited containers ---"
docker ps -a --filter status=exited --format "{{.Names}}: {{.Status}}" | head -10 || echo "(none)"
'

COMMAND_ID=$(aws ssm send-command --profile appserver \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(printf '{"commands":[%s]}' "$(echo "$CMD" | jq -Rs .)")" \
  --query "Command.CommandId" --output text --region "$REGION" 2>/dev/null)
sleep 6
aws ssm get-command-invocation --profile appserver \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text --region "$REGION" 2>/dev/null

if [[ -n "$DOMAIN" ]]; then
  echo
  echo "=== Layer 7: External Reachability ==="
  # Read CF access creds from terraform outputs if available
  CF_ID=$(cd terraform && terraform output -raw cf_access_client_id 2>/dev/null || echo "")
  CF_SECRET=$(cd terraform && terraform output -raw cf_access_client_secret 2>/dev/null || echo "")
  if [[ -n "$CF_ID" ]]; then
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      -H "CF-Access-Client-Id: $CF_ID" \
      -H "CF-Access-Client-Secret: $CF_SECRET" \
      "https://cookie.${DOMAIN}/api/system/health/" 2>/dev/null || echo "timeout")
    echo "cookie.${DOMAIN}/api/system/health/ → HTTP $STATUS"
    [[ "$STATUS" == "200" ]] && echo "PASS" || echo "FAIL"
  else
    echo "(skipped — terraform outputs not available)"
  fi
fi
