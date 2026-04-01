# AWS Access and IAM

How appserver's two-tier IAM model works and which profile to use for what.

## Profiles

### Deployer Profile (`AWS_PROFILE=appserver`)
- **Used for:** All routine operations (diagnostics, deploy, app management, config push, spend)
- **User:** `appserver-deployer` IAM user
- **Created by:** `appserver.sh init`
- **Policies:** 3 deployer policies (compute, iam-ssm, monitoring-storage)

### Admin Profile (default / no AWS_PROFILE)
- **Used for:** Bootstrap only (`appserver.sh init`)
- **User:** `rockport-admin` (shared admin user across projects)
- **Policy:** `AppserverAdmin` (auto-created by init)

## When to Use Each

### Use Deployer (default for appserver-ops)

Almost everything:
- `aws ec2 describe-instances` (instance status)
- `aws ssm send-command` / `describe-instance-information` (remote commands)
- `aws ssm get-parameter` (read secrets like tunnel token)
- `aws s3 cp` (upload/download artifacts)
- `aws cloudwatch describe-alarms` (alarm status)
- `aws ce get-cost-and-usage` (spend data)
- `terraform plan` / `terraform apply` / `terraform destroy`
- All `appserver.sh` commands except `init`

### Use Admin (escalation only)

Only when the issue involves:
- Creating or modifying IAM policies
- Creating or modifying IAM users
- Managing the state bucket
- First-time setup (`appserver.sh init`)

**To escalate:** Unset the deployer profile:
```bash
unset AWS_PROFILE
# Now commands use the default credential chain (rockport-admin)
```

**Appserver-ops should almost never need admin.** If a fix requires IAM policy changes, those changes should go through terraform (which runs as the deployer), not manual IAM API calls.

## Deployer Capabilities Detail

### Compute (deployer-policies/compute.json)
- EC2: Full describe (including DescribeInstanceCreditSpecifications), create/modify/terminate with `Project=appserver` tag
- EC2: Describe security group rules (for zero-inbound audits)
- RunInstances: Instance tagged with `Project=appserver`; passthrough for volumes, network interfaces, images, subnets, security groups
- DLM: Lifecycle policy management (EBS snapshots) + GetLifecyclePolicies for status checks

### IAM + SSM (deployer-policies/iam-ssm.json)
- IAM: Manage `appserver-*` roles, instance profiles, policies
- IAM: Read-only on deployer's own user (`GetUser`, `ListAttachedUserPolicies`)
- SSM: SendCommand + StartSession to appserver-tagged instances
- SSM: GetCommandInvocation + DescribeInstanceInformation (diagnostics)
- **Security:** Explicit Deny on privilege escalation beyond Appserver policies

### Monitoring + Storage (deployer-policies/monitoring-storage.json)
- CloudWatch: DescribeAlarms for `appserver-*` alarms (auto-recovery status)
- Budgets: View and modify appserver budget
- S3: Full access to `appserver-artifacts-*` and state bucket
- Cost Explorer: Read-only (`ce:GetCostAndUsage`)

## SSM Command Patterns

### Send a command and get output
```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
INSTANCE_ID=$(cd $PROJECT_ROOT/terraform && terraform output -raw instance_id 2>/dev/null)

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"$YOUR_COMMAND\"]}" \
  --query 'Command.CommandId' --output text --region "$REGION")

# Wait briefly for execution
sleep 3

# Get result
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

### Important SSM notes
- Commands run as `root` by default on the instance
- If SSM times out, the instance may be starting up (wait 2-3 min) or unreachable
- The `appserver.sh` CLI has a built-in `ssm_run` helper that handles send + wait + get

## Secret Locations

| Secret | Location | Access |
|--------|----------|--------|
| Tunnel token | SSM `/appserver/tunnel-token` | Terraform manages |
| CF API token | `terraform/.env` | Local file, gitignored |
| CF Access client ID | Terraform output (sensitive) | `terraform output cf_access_client_id` |
| CF Access client secret | Terraform output (sensitive) | `terraform output cf_access_client_secret` |
| App secrets | Instance `/opt/appserver/apps/<name>/.env` | Via `appserver.sh app env` |

## Security Audit Capabilities (Deployer)

The deployer profile can perform these security checks without escalation:

| Check | Command | Expected |
|-------|---------|----------|
| Zero inbound SG rules | `ec2 describe-security-group-rules` | No non-egress rules |
| Auto-recovery alarm | `cloudwatch describe-alarms --alarm-name-prefix appserver` | StateValue: OK |
| Snapshot policy | `dlm get-lifecycle-policies` | State: ENABLED |
| Instance role policies | Requires admin — use `iam list-role-policies` | s3-artifacts, ssm-parameters + SSM Core |
| Cookie security | SSM: `manage.py check --deploy` | 0 issues |
| Cookie audit trail | SSM: `python manage.py cookie_admin audit --json` | No unexpected registrations |
| Cost anomalies | `ce get-cost-and-usage` (us-east-1) | Within budget |

**Cannot do with deployer (requires admin):**
- `iam:ListRolePolicies` / `iam:ListAttachedRolePolicies` on the instance role
- Modifying IAM policies directly (changes go through terraform + `init`)

## Region

Region is read from `terraform/terraform.tfvars`, not hardcoded:
```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
```

Default is `eu-west-2` (London).
