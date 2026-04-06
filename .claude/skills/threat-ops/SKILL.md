---
name: threat-ops
description: "Analyze server threats, review reports, and enact defensive actions. Use when: threat analysis, suspicious traffic, block IPs, review attacks, security posture."
user-invocable: true
argument-hint: "[analyze | review | block <ip> | status]"
allowed-tools: "Read, Grep, Glob, Bash, Agent"
effort: high
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

Detect and respond to threats against appserver — analyze Traefik access logs for attack patterns, review threat reports, and enact defensive actions (IP blocks) via Cloudflare WAF API.

For **infrastructure issues** (downtime, deploy failures, routing), use `/appserver-ops` instead. For **app-specific issues** (Cookie, passkeys, cron), use `/cookie-ops`.

Input can be:
- Mode keywords: "analyze", "review", "block 1.2.3.4", "status"
- Free-form: "what's attacking the server?", "block that scanner", "show me the latest report"
- No input defaults to **analyze** mode

## Workflow

### Mode: Analyze (default)

Trigger: `/threat-ops`, `/threat-ops analyze`, "run threat analysis", "check for attacks"

1. Run analysis via subagent:
   ```bash
   ./scripts/appserver.sh threats --since 24h
   ```
2. Read the generated `reports/threats/<timestamp>/report.json`
3. Present SUMMARY.md to the user
4. For each **high-confidence** recommendation, offer to enact it:
   - "Finding F-001: zgrab scanner from 45.33.32.156 (847 requests, 100% errors). Block?"
5. If user approves, run:
   ```bash
   ./scripts/appserver.sh threats block <ip> --note "<rationale>"
   ```
6. Record all actions taken

### Mode: Review

Trigger: `/threat-ops review`, "show threat report", "what attacks are happening"

1. Run `./scripts/appserver.sh threats list` to show available reports
2. Read the latest (or user-specified) report:
   ```bash
   ./scripts/appserver.sh threats report [<timestamp>]
   ```
3. Present findings with context and severity
4. Highlight any unenacted high-confidence recommendations

### Mode: Block

Trigger: `/threat-ops block 1.2.3.4`, "block this IP"

1. Validate IP format
2. Check if already blocked:
   ```bash
   ./scripts/appserver.sh threats blocked
   ```
3. Block the IP:
   ```bash
   ./scripts/appserver.sh threats block <ip> --note "<reason>"
   ```
4. Verify success

### Mode: Status

Trigger: `/threat-ops status`, "what's blocked", "show blocked IPs"

1. List currently blocked IPs:
   ```bash
   ./scripts/appserver.sh threats blocked
   ```
2. Show latest report summary statistics

## Report Format

Always produce a structured report:

```markdown
## Threat Ops Report

**Action**: ANALYZED | BLOCKED | REVIEWED
**Timestamp**: [when]
**Status**: CLEAN | THREATS_DETECTED | ACTION_TAKEN | ERROR

### Summary
[Key findings or action result]

### Findings (if analyze/review)
[Top findings by severity]

### Actions Taken (if block)
- [What was done, CF rule ID, verification]

### Recommendations
- [Remaining unenacted recommendations]

### For the user
- [Next steps or guidance]
```

## Conventions

- `$PROJECT_ROOT` means the appserver repo root (working directory)
- Reports are stored in `reports/threats/<timestamp>/` (gitignored)
- Report files: `report.json` (machine), `SUMMARY.md` (human), `actions.json` (audit trail)
- All blocking uses Cloudflare WAF IP access rules (not iptables, not Terraform)
- Use the CLI (`appserver.sh threats`) when it wraps the operation you need

## Gotchas

- **SSM commands return async.** `ssm_run` handles polling, but analysis can take up to 2 minutes for large log files. Be patient.
- **Access logs must be enabled first.** If no logs exist, run `config push` to deploy the updated Traefik config, wait for traffic.
- **CF API rate limits.** 1200 requests/5 minutes. Manual blocking won't hit this, but be aware for bulk operations.
- **CF edge data is optional.** Requires Analytics:Read permission on the API token. If missing, `cf_edge` will be null — not an error.
- **CLOUDFLARE_API_TOKEN must be set.** Block/unblock/blocked commands need it. The analyze command needs it for CF edge data but works without it.
- **Logrotate on existing instances.** bootstrap.sh only runs on first boot. For existing instances, `config push` deploys the logrotate config via SSM.
- **Report timestamps are UTC.** Directory names use `YYYYMMDD-HHMMSS` format in UTC.

## Rules

1. **Subagents for CLI commands, main context for decisions.** Run `appserver.sh threats` commands through subagents.
2. **Never auto-block without user confirmation.** Always present findings and ask before enacting block recommendations.
3. **High confidence only for auto-suggest.** Only offer to block IPs with `confidence: high` recommendations.
4. **Phase 4 is mandatory.** Always produce the structured ops report.
5. **Use the CLI.** `appserver.sh threats` wraps all threat operations.
6. **Track actions.** Every block/unblock is recorded in actions.json for audit trail.
