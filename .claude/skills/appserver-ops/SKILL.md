---
name: appserver-ops
description: "Diagnose, fix, and advise on appserver infrastructure issues. Use when: checking if the server is up/healthy, debugging connection failures (timeouts, 502s, 403s), Traefik routing issues, Cloudflare Tunnel problems, EC2 instance management, resource pressure (memory, disk), security posture, or deployment failures. Also triggers for: 'is it up', 'check the infra', 'deploy failed', 'instance won't start'."
user-invocable: true
argument-hint: "[symptom or error description]"
allowed-tools: "Read, Grep, Glob, Bash, Agent"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

Diagnose and fix **infrastructure-level** issues for appserver — a Docker app hosting platform on EC2 behind Cloudflare Tunnel with Traefik reverse proxy.

For **app-specific** issues (Cookie logs, cookie_admin, device pairing, passkeys, cron jobs), use `/cookie-ops` instead. When unsure, start here — infrastructure issues affect all apps.

Input can be:
- Free-form symptom descriptions ("everything is down", "deploy failed", "502 errors")
- Raw error output from the CLI or terraform
- Health check requests ("is appserver healthy?", "is it up?")
- Specific error messages or HTTP status codes

## Workflow

Execute these 4 phases in order. Every phase is mandatory.

### Phase 1: Triage

Investigate using **subagents** to keep diagnostic noise out of the main context. Each subagent should:
- Run the specific AWS CLI / SSM / curl commands needed
- Return a **summary** (5-10 lines max), not raw output
- Include specific error messages, timestamps, and status codes

Use [diagnostics.md](references/diagnostics.md) for exact commands. Work top-down, skip irrelevant layers.

**Layer order:**
1. Instance state (running? SSM reachable?)
2. Container health (Docker containers running? Traefik healthy?)
3. App health (specific app containers, compose status)
4. Recent logs (Docker logs for Traefik, cloudflared, or specific app)
5. External reachability (curl through Cloudflare Tunnel)
6. Resource pressure (memory, disk — t4g.small has 2GB)
7. Security posture (SG rules, CloudWatch alarms, DLM snapshots)

**AWS profile:** Use `AWS_PROFILE=appserver` (deployer) for all commands. See [aws-access.md](references/aws-access.md) for escalation.

### Phase 2: Diagnosis

Determine:
1. **What is broken** — specific service or component
2. **Root cause** — why it broke
3. **Layer** — which architectural layer
4. **Severity** — operational (restart fixes it) vs. config bug vs. infrastructure issue

Consult [common-issues.md](references/common-issues.md) for known symptom-to-cause mappings.

**Immediate operational actions** (restart instance, restart container) can be taken now. But if the root cause is a bug or config issue, a proper fix is still needed.

Report your diagnosis to the user before proceeding to Phase 3.

### Phase 3: Fix

1. Operational issue (restart, start instance): use the CLI or SSM
2. Code/config change: edit files and deploy
3. Terraform change: update terraform files and run deploy

**IaC is truth.** Infrastructure changes MUST be reflected in the codebase and applied via `./scripts/appserver.sh deploy` or `config push`.

### Phase 4: Verify & Report

1. Re-check the original symptom
2. Run `./scripts/appserver.sh status` to confirm overall health

**Always produce:**

```markdown
## Appserver Ops Report

**Status**: RESOLVED | MITIGATED | ESCALATED
**Root cause**: What broke and why
**Fix applied**: What changed
**Deployed**: Yes/No
**Health check**: Containers running, resources OK

### Actions taken
- [List of specific actions]

### For the user
- [Follow-up needed or guidance]
```

**Status definitions:**
- **RESOLVED** — Root cause fixed, health checks passing
- **MITIGATED** — Service restored but root cause fix pending
- **ESCALATED** — Cannot be fixed automatically (AWS outage, needs admin IAM, app code bug)

## Conventions

- `$PROJECT_ROOT` in reference files means the appserver repo root (the working directory)
- Use the CLI (`appserver.sh`) when it wraps the operation you need

## Gotchas

- **SSM commands return async.** `send-command` returns immediately. You must `sleep 3` then `get-command-invocation`. Forgetting this gives empty results.
- **Instance takes ~3 minutes after start.** Docker and Traefik need boot time. Don't report "down" until SSM shows online for 3+ minutes.
- **Config push is not atomic.** Downloads, extracts, restarts Traefik. If it fails mid-way, Traefik may be down. Check SSM output for which step failed.
- **`terraform output` needs init.** Read values from `terraform.tfvars` directly or run init first.
- **Cloudflare 403 vs app error.** CF 403 = missing CF-Access headers or expired service token. App errors come as different codes. Check response body.
- **Docker logs may be verbose.** Always use `--since 10m` or `--tail 50`.
- **ARM architecture.** t4g.small is Graviton (aarch64). Images must support `linux/arm64`.
- **App secrets are on the instance.** `.env` at `/opt/appserver/apps/<name>/.env`. Use `app env` to view/set.
- **Traefik routes by Docker labels.** If app runs but isn't reachable, check labels and `appserver` network membership.
- **Zone-wide WAF rules.** Rockport's WAF custom rules affect the whole zone unless scoped by hostname. Check Security > Events for "Block non-allowlisted paths".
- **SSL inside containers is unnecessary.** Traffic: Client > Cloudflare (TLS) > Tunnel > Traefik (:80) > Container (:80).
- **X-Forwarded-Proto must be preserved.** If an app's nginx overwrites this with `$scheme`, Django redirects break.
- **cloudflared is systemd, not Docker.** Use `systemctl status cloudflared` and `journalctl -u cloudflared` via SSM.
- **SSM TimeoutSeconds minimum is 30.** Below 30 fails with `ParamValidation`.
- **Destroy keeps AppserverAdmin policy.** Intentional — allows re-bootstrap without root.

## Rules

1. **Subagents for I/O, main context for decisions.** Raw output goes through subagents only.
2. **Deployer profile by default.** Only escalate to admin for IAM policy changes.
3. **IaC must match reality.** Never let code and infrastructure diverge.
4. **Phase 4 is mandatory.** Always produce the structured ops report.
5. **Use the CLI when possible.** `appserver.sh` wraps most operations.
6. **Delegate app-specific issues.** Cookie diagnostics belong in `/cookie-ops`.
