# Diagnostic Procedures

Layer-by-layer diagnostic commands for appserver infrastructure. Use these in subagents to keep raw output out of the main context.

## Prerequisites

All commands use the deployer AWS profile unless noted otherwise.

```bash
export AWS_PROFILE=appserver
```

To get the instance ID and region:
```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
INSTANCE_ID=$(cd $PROJECT_ROOT/terraform && terraform output -raw instance_id 2>/dev/null)
```

## Layer 1: Instance State

**Check if running:**
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=appserver" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Launch:LaunchTime}' \
  --output table --region "$REGION"
```

**Start a stopped instance:**
```bash
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
```

Or use the CLI: `./scripts/appserver.sh start`

## Layer 2: SSM Reachability

**Check SSM agent status:**
```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' \
  --output table --region "$REGION"
```

If PingStatus is not "Online", the instance may be starting up (wait 2-3 minutes after start) or the SSM agent may be down.

## Layer 3: Container Health (via SSM)

**Check all containers:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker ps --format \"table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\" && echo --- && docker ps -a --filter status=exited --format \"table {{.Names}}\\t{{.Status}}\" | head -10"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"

sleep 3

aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

**Check Traefik health specifically:**
```bash
# Traefik has a ping health check
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker exec traefik traefik healthcheck --ping 2>&1 && echo HEALTHY || echo UNHEALTHY"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 4: App Health (via SSM)

**Check a specific app:**
```bash
# Replace APP with the app name (e.g., cookie)
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["cd /opt/appserver/apps/APP && docker compose ps 2>&1"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**List all apps and their status:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["for d in /opt/appserver/apps/*/; do [ -d \"$d\" ] || continue; app=$(basename \"$d\"); status=$(cd \"$d\" && docker compose ps --format \"{{.Name}}: {{.Status}}\" 2>/dev/null); if [ -n \"$status\" ]; then echo \"$status\"; else echo \"$app: not running\"; fi; done"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

Or use the CLI: `./scripts/appserver.sh app list`

## Layer 5: Recent Logs (via SSM)

**Traefik logs (last 10 minutes):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker logs traefik --since 10m 2>&1 | tail -30"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**App logs:**
```bash
# Replace APP with the app name
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["cd /opt/appserver/apps/APP && docker compose logs --since 10m --tail 50 2>&1"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

Or use the CLI: `./scripts/appserver.sh logs APP`

**Cloudflared logs:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker logs cloudflared --since 10m 2>&1 | grep -iE \"error|ERR|fail\" | tail -20"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 6: Resource Pressure

**Memory (t4g.small has 2GB):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["free -m && echo --- && docker stats --no-stream --format \"table {{.Name}}\\t{{.MemUsage}}\\t{{.CPUPerc}}\""]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Disk space:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["df -h / && echo --- && docker system df"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 7: External Reachability

**Test through Cloudflare Tunnel (requires CF-Access headers):**
```bash
CF_CLIENT_ID=$(cd $PROJECT_ROOT/terraform && terraform output -raw cf_access_client_id 2>/dev/null)
CF_CLIENT_SECRET=$(cd $PROJECT_ROOT/terraform && terraform output -raw cf_access_client_secret 2>/dev/null)
DOMAIN=$(grep '^domain' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')

# Test a specific app subdomain
curl -s -o /dev/null -w "%{http_code}" \
  -H "CF-Access-Client-Id: ${CF_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_CLIENT_SECRET}" \
  "https://cookie.${DOMAIN}/"
```

## Restarting Services (via SSM)

**Restart Traefik:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["cd /opt/appserver/traefik && docker compose restart && sleep 3 && docker compose ps"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Restart a specific app:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["cd /opt/appserver/apps/APP && docker compose restart && sleep 3 && docker compose ps"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

Or use the CLI: `./scripts/appserver.sh app restart APP`

## Cookie App Diagnostics

Cookie provides management commands that return JSON — ideal for SSM-based diagnostics:

**Post-deploy health check:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker exec cookie-web python manage.py cookie_admin status --json"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```
Returns: `{"ok": true/false, "auth_mode": "...", "database": "...", "migrations": "...", "users": {...}, "passkeys": N, "webauthn": {...}}`

**Security audit (last 24h):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker exec cookie-web python manage.py cookie_admin audit --json"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```
Returns: `{"ok": true/false, "events": [{"time": "...", "type": "registration|login|device_code", "username": "..."}]}`

## Using appserver.sh CLI

The CLI wraps many of these operations. For quick checks, prefer the CLI:

```bash
cd $PROJECT_ROOT
./scripts/appserver.sh status          # Containers + resource usage
./scripts/appserver.sh logs [app]      # Stream container logs
./scripts/appserver.sh spend           # AWS cost breakdown
./scripts/appserver.sh app list        # All apps + status
./scripts/appserver.sh app restart APP # Restart app containers
./scripts/appserver.sh app env APP     # View app env vars (masked)
./scripts/appserver.sh config push     # Push config + restart Traefik
```
