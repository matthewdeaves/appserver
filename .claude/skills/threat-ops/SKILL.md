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

Detect and respond to threats against appserver. Analyzes multiple data sources:
- **Traefik access logs** — scanner paths, UA signatures, traversal, rate anomalies
- **Cookie app security** — registration/auth events, nginx 4xx/5xx, unusual patterns
- **Container events** — die/OOM events (DoS indicator)
- **cloudflared tunnel** — reconnection warnings, auth failures
- **Cloudflare edge** — WAF blocks + rate-limit triggers before they hit Traefik
- **AWS cost** — spend anomalies indicating unauthorized resource use

For **infrastructure issues** (downtime, deploy failures, routing), use `/appserver-ops` instead. For **app-specific issues** (Cookie, passkeys, cron), use `/cookie-ops`.

Input can be:
- Mode keywords: "analyze", "review", "block 1.2.3.4", "status"
- Free-form: "what's attacking the server?", "block that scanner", "show me the latest report"
- No input defaults to **analyze** mode

## Auth

Run `./scripts/appserver.sh auth` once per shell session. The CLI maps each `threats` subcommand to the right operator role automatically:

- `threats` (analyze), `threats list`, `threats report`, `threats blocked`, `threats allowed` → `appserver-readonly-role`
- `threats block`, `threats unblock`, `threats allow`, `threats unallow` → `appserver-cookie-ops-role` (Cloudflare API + SSM)

Cloudflare API calls use the `CLOUDFLARE_API_TOKEN` env var (set via the local `terraform/.env`) — that flow is unchanged.

## Scripts

Helper scripts in `scripts/` — run from the appserver repo root:

| Script | Purpose |
|--------|---------|
| `scripts/collect-app-security.sh [--since <duration>]` | SSM: cookie audit + nginx errors + container events + tunnel warnings → JSON |
| `scripts/check-cost.sh` | Local AWS CE call: yesterday vs day-before spend + anomaly flag → JSON |

These are called automatically by `appserver.sh threats` during analysis. Use them standalone for quick targeted checks.

## Workflow

### Mode: Analyze (default)

Trigger: `/threat-ops`, `/threat-ops analyze`, "run threat analysis", "check for attacks"

1. Run full analysis via subagent:
   ```bash
   ./scripts/appserver.sh threats --since 24h
   ```
   This collects all data sources in sequence: Traefik logs → CF edge → app security (SSM) → cost check.
2. Read the generated `reports/threats/<timestamp>/report.json`
3. Present `SUMMARY.md` to the user — it includes Traefik findings, app security, container events, tunnel health, and cost
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

### App Security
[Registrations, auth events, nginx error counts]

### Container / Tunnel / Cost (if noteworthy)
[Container die events, tunnel reconnections, cost anomaly]

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

- **SSM commands return async.** Analysis can take up to 2 minutes for large log files. Be patient.
- **App security collection adds ~15s.** `_collect_app_security` runs an SSM script gathering cookie audit + nginx + container events. This is a second SSM round-trip after the Traefik analysis.
- **CF edge data requires Zone Analytics → Read.** The `firewallEventsAdaptive` GraphQL query is a zone-level query — it needs **Zone Analytics → Read** on the CF API token (not Account Analytics → Read). If `cf_edge.available` is false in the report, check token permissions.
- **Access logs must be enabled first.** If no Traefik logs exist, run `config push` to deploy the updated Traefik config, wait for traffic.
- **Cost check uses us-east-1 always.** AWS Cost Explorer API endpoint is us-east-1 regardless of resource region — this is expected.
- **Cookie audit shows events not time-filtered.** `cookie_admin audit` returns the N most recent events regardless of time window. Counts in the report reflect the last 200 events, not the exact time window.
- **CF API rate limits.** 1200 requests/5 minutes. Manual blocking won't hit this, but be aware for bulk operations.
- **Report timestamps are UTC.** Directory names use `YYYYMMDD-HHMMSS` format in UTC.
- **CLOUDFLARE_API_TOKEN must be set.** Block/unblock/blocked commands need it. The analyze command needs it for CF edge + WAF data.

## Rules

1. **Subagents for CLI commands, main context for decisions.** Run `appserver.sh threats` commands through subagents.
2. **Never auto-block without user confirmation.** Always present findings and ask before enacting block recommendations.
3. **High confidence only for auto-suggest.** Only offer to block IPs with `confidence: high` recommendations.
4. **Phase 4 is mandatory.** Always produce the structured ops report.
5. **Use the CLI.** `appserver.sh threats` wraps all threat operations.
6. **Track actions.** Every block/unblock is recorded in actions.json for audit trail.
