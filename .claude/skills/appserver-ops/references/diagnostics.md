# Diagnostic Procedures

Layer-by-layer diagnostic commands for appserver infrastructure. Use these in subagents to keep raw output out of the main context.

For Cookie-specific diagnostics (cookie_admin, cron jobs, cleanup commands), see `/cookie-ops`.

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

**Cloudflared logs (systemd service, NOT a Docker container):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u cloudflared --since \"10 min ago\" --no-pager 2>&1 | grep -iE \"error|ERR|fail|warn\" | tail -20"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Cloudflared tunnel status:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl is-active cloudflared && cloudflared --version && journalctl -u cloudflared --since \"5 min ago\" --no-pager 2>&1 | grep -iE \"connection|registered|reconnect\" | tail -5"]}' \
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

## Layer 8: Security Posture

**Verify zero-inbound security group (should have NO inbound rules):**
```bash
SG_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text --region "$REGION")

aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" \
  --query 'SecurityGroupRules[?!IsEgress].{Protocol:IpProtocol,FromPort:FromPort,ToPort:ToPort,CIDR:CidrIpv4}' \
  --output table --region "$REGION"
```
Expected: empty table (zero inbound rules). Any inbound rule is a security issue.

**CloudWatch alarm status:**
```bash
aws cloudwatch describe-alarms --alarm-name-prefix "appserver" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --output table --region "$REGION"
```

**DLM snapshot policy status:**
```bash
aws dlm get-lifecycle-policies \
  --query 'Policies[].{Id:PolicyId,State:State,Description:Description}' \
  --output table --region "$REGION"
```
Should show ENABLED. If ERROR or DISABLED, snapshots aren't happening.

**Instance role audit (verify least-privilege) — requires admin profile:**
```bash
# These commands require admin (unset AWS_PROFILE), deployer cannot list role policies
unset AWS_PROFILE
aws iam list-role-policies --role-name appserver-instance-role --output json
aws iam list-attached-role-policies --role-name appserver-instance-role --output json
```
Expected: inline policies `s3-artifacts` and `ssm-parameters`, attached policy `AmazonSSMManagedInstanceCore`. Anything else is unexpected.

## Layer 9: AWS Cost and Budget

**Cost breakdown (last 30 days):**
```bash
cd $PROJECT_ROOT
./scripts/appserver.sh spend
```

Or directly via AWS CLI:
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '30 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics BlendedCost \
  --filter '{"Tags":{"Key":"Project","Values":["appserver"]}}' \
  --region us-east-1 --output json
```
Note: Cost Explorer API always uses `us-east-1` regardless of resource region.

**Budget alarm status:**
```bash
aws budgets describe-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget-name appserver-monthly-total --region us-east-1 --output json \
  --query 'Budget.{Limit:BudgetLimit,Actual:CalculatedSpend.ActualSpend}'
```

## Using appserver.sh CLI

The CLI wraps many of these operations. For quick checks, prefer the CLI:

```bash
cd $PROJECT_ROOT
./scripts/appserver.sh status          # Containers + resource usage
./scripts/appserver.sh logs [app]      # Container logs (Traefik + all apps, or specific app)
./scripts/appserver.sh spend           # AWS cost breakdown (last 30 days)
./scripts/appserver.sh app list        # All apps + status
./scripts/appserver.sh app restart APP # Restart app containers
./scripts/appserver.sh app env APP     # View app env vars (masked)
./scripts/appserver.sh app env APP KEY=VALUE  # Set env vars
./scripts/appserver.sh config push     # Push config + restart Traefik
./scripts/appserver.sh start           # Start stopped EC2 instance
./scripts/appserver.sh stop            # Stop EC2 instance
./scripts/appserver.sh ssh             # Interactive SSM session
./scripts/appserver.sh deploy          # terraform init + apply + upload artifacts
./scripts/appserver.sh destroy         # terraform destroy + optional cleanup
./scripts/appserver.sh app init NAME   # Generate secrets + create .env on instance
./scripts/appserver.sh app deploy NAME # Pull image + restart app
./scripts/appserver.sh app remove NAME # Stop + remove app (preserves volumes)
```
