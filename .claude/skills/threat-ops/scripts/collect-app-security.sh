#!/usr/bin/env bash
# Collect app-layer security data from the instance and print JSON to stdout.
# Equivalent to the _collect_app_security step inside `appserver.sh threats`.
# Run from the appserver repo root.
#
# Usage: ./collect-app-security.sh [--since <duration>]
#   --since  Time window (default: 24h). Accepts e.g. 1h, 6h, 24h, 7d.
#
# Output: JSON with keys: app_security, app_errors, container_events, tunnel_health
# Exit 0 = success, exit 1 = SSM unreachable or data collection failed

set -euo pipefail
cd "$(dirname "$0")/../../../.." 2>/dev/null || true

SINCE="${2:-24h}"
if [[ "${1:-}" == "--since" ]]; then SINCE="$2"; fi
[[ "$SINCE" =~ ^[0-9]+(h|d)$ ]] || { echo "Usage: $0 [--since <duration>]" >&2; exit 1; }

NUM="${SINCE%[hd]}"; UNIT="${SINCE: -1}"
case "$UNIT" in
  h) DURATION_SEC=$((NUM * 3600)) ;;
  d) DURATION_SEC=$((NUM * 86400)) ;;
esac

# Resolve instance ID via AWS CLI (no terraform required)
REGION=$(grep '^region' terraform/terraform.tfvars 2>/dev/null \
  | sed 's/.*= *"\(.*\)"/\1/' || echo "eu-west-2")
INSTANCE_ID=$(aws ec2 describe-instances --profile appserver \
  --filters "Name=tag:Name,Values=appserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] \
  || { echo '{"error":"instance not found or not running"}'; exit 1; }

APP_SCRIPT="DURATION_SEC=$DURATION_SEC
$(cat <<'EOF'
set -e
CUTOFF_ISO=$(date -u -d "$DURATION_SEC seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u -v-"${DURATION_SEC}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u +"%Y-%m-%dT%H:%M:%SZ")
AUDIT='{"ok":false,"events":[]}'
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  AUDIT=$(docker exec cookie-web python manage.py cookie_admin audit --json --lines 200 2>/dev/null \
          || echo '{"ok":false,"events":[]}')
fi
NGINX_5XX=0; NGINX_4XX=0; TOP_ERROR_PATHS=""
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  NGINX_LINES=$(docker exec cookie-web tail -2000 /var/log/nginx/access.log 2>/dev/null || echo "")
  if [[ -n "$NGINX_LINES" ]]; then
    NGINX_5XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^5[0-9]{2}$' || echo 0)
    NGINX_4XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^4[0-9]{2}$' || echo 0)
    TOP_ERROR_PATHS=$(echo "$NGINX_LINES" | awk '$9 ~ /^[45][0-9]{2}$/ {print $7}' \
      | sort | uniq -c | sort -rn | head -10 \
      | awk '{printf "%s:%s,", $2, $1}' | sed 's/,$//' || echo "")
  fi
fi
UNTIL_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTAINER_RESTARTS=$(docker events --since "$CUTOFF_ISO" --until "$UNTIL_ISO" \
  --filter type=container --filter event=die --filter event=oom \
  --format '{{.Time}} {{.Actor.Attributes.name}} {{.Action}} exit={{.Actor.Attributes.exitCode}}' \
  2>/dev/null | head -20 || echo "")
TUNNEL_WARNINGS=$(journalctl -u cloudflared --since "$CUTOFF_ISO" \
  --no-pager -o short 2>/dev/null | grep -iE "error|warn|failed|disconnect|reconn|retry" \
  | tail -10 || echo "")
jq -n \
  --arg audit_raw "$AUDIT" --arg nginx_5xx "$NGINX_5XX" --arg nginx_4xx "$NGINX_4XX" \
  --arg top_error_paths "$TOP_ERROR_PATHS" --arg container_restarts "$CONTAINER_RESTARTS" \
  --arg tunnel_warnings "$TUNNEL_WARNINGS" \
  '{
    app_security: (
      ($audit_raw | fromjson? // {"ok":false,"events":[]}) |
      { audit_ok: (.ok // false), event_count: (.events // [] | length),
        recent_registrations: (.events // [] | map(select(.type == "registration")) | length),
        recent_logins: (.events // [] | map(select(.type == "passkey_login" or .type == "device_code_authorized")) | length),
        events_sample: (.events // [] | .[0:5]) }
    ),
    app_errors: {
      nginx_5xx: ($nginx_5xx | tonumber? // 0), nginx_4xx: ($nginx_4xx | tonumber? // 0),
      top_error_paths: (if $top_error_paths == "" then []
        else ($top_error_paths | split(",") | map(select(length > 0))
          | map(split(":") | {path: .[0], count: (.[1] | tonumber? // 0)})) end)
    },
    container_events: { restarts: (if $container_restarts == "" then []
      else ($container_restarts | split("\n") | map(select(length > 0))) end) },
    tunnel_health: { warnings: (if $tunnel_warnings == "" then []
      else ($tunnel_warnings | split("\n") | map(select(length > 0))) end) }
  }'
EOF
)"

COMMAND_ID=$(aws ssm send-command --profile appserver \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "$(printf '{"commands":[%s]}' "$(echo "$APP_SCRIPT" | jq -Rs .)")" \
  --query "Command.CommandId" --output text --region "$REGION" 2>/dev/null)
[[ -n "$COMMAND_ID" ]] || { echo '{"error":"send-command failed"}'; exit 1; }

sleep 8

aws ssm get-command-invocation --profile appserver \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query "StandardOutputContent" --output text --region "$REGION" 2>/dev/null
