# AWS Access and IAM

How appserver's IAM model works and which role to use for what.

## Auth flow

Run once per shell session:

```bash
./scripts/appserver.sh auth
```

The CLI prompts for a TOTP code, calls `sts:AssumeRole` against the
right operator role for the work, and writes a 1-hour STS session to a
profile in `~/.aws/credentials`. Subsequent CLI subcommands automatically
re-use cached sessions and prompt for re-auth on expiry.

## Roles

The CLI maps each subcommand to one of three operator roles:

### `appserver-readonly-role` (diagnostic, default)
- **Used for:** `status`, `health`, `users`, `logs`, `spend`, `app list`, `threats analyze` / `report` / `list` / `blocked` / `allowed`, `setup unlock`
- **Permissions:** read-only AWS surface (Describe*, Get*, ListBucket on artifacts/state, no SendCommand, no IAM mutation)
- **MaxSessionDuration:** 1 hour

### `appserver-cookie-ops-role` (app-layer mutations)
- **Used for:** `app deploy`, `app init`, `app remove`, `app restart`, `app env`, `config push`, `threats block` / `unblock` / `allow` / `unallow`
- **Permissions:** readonly + `ssm:SendCommand` and `ssm:StartSession` on the `Project=appserver`-tagged instance, parameter RW under `/appserver/*`
- **MaxSessionDuration:** 1 hour

### `appserver-deploy-role` (infra changes)
- **Used for:** `deploy`, `destroy`, `start`, `stop`, `ssh`
- **Permissions:** equivalent to the legacy deployer (full compute + iam-ssm + monitoring-storage)
- **MaxSessionDuration:** 1 hour

### Admin (escalation only)
- **Used for:** `appserver.sh init` (creates IAM policies, deployer user, state bucket), MFA recovery
- **User:** `rockport-admin` (shared admin user across projects)
- **Policy:** `AppserverAdmin` (auto-created by init)

`init` and `destroy --cleanup-bootstrap` explicitly `unset AWS_PROFILE` to drop to the admin credential chain. Everything else goes through the role flow.

## Recovery

If MFA is lost, re-enrol via the AWS console using `rockport-admin` (the IAM admin retains the `AppserverAdmin` managed policy throughout). See `HANDOFF.md` for the recovery walkthrough.

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

**Cannot do with deploy-role (requires admin):**
- `iam:ListRolePolicies` / `iam:ListAttachedRolePolicies` on the instance role
- Modifying IAM policies directly (changes go through terraform + `init`)
- Creating or removing the deployer user, IAM policies, or state bucket

## Region

Region is read from `terraform/terraform.tfvars`, not hardcoded:
```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
```

Default is `eu-west-2` (London).
