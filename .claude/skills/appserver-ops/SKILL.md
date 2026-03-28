---
name: appserver-ops
description: "Diagnose, fix, and advise on appserver infrastructure issues. ALWAYS USE THIS SKILL when the user asks anything about appserver infrastructure — including casual questions like 'is it ok', 'is it up', 'is it working', 'check the infra', 'how's the server', 'did the deploy work', or 'is everything healthy'. Also use when: debugging errors (timeouts, 502s, container failures, DNS issues), checking health or status, investigating app deployment problems, troubleshooting Cloudflare Tunnel issues, or when the user mentions appserver is down, broken, slow, or erroring."
user-invocable: true
argument-hint: "[symptom or error description]"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

Diagnose infrastructure issues, apply fixes, and produce structured advice. Appserver is a Docker app hosting platform on EC2 behind Cloudflare Tunnel with Traefik reverse proxy.

Input can be:
- Free-form symptom descriptions ("cookie app is down", "deploy failed")
- Raw error output from the CLI or terraform
- Health check requests ("is appserver healthy?")
- Specific error messages or HTTP status codes

## Workflow

Execute these 4 phases in order. Every phase is mandatory.

### Phase 1: Triage

Investigate the issue using **subagents** to keep diagnostic noise out of the main context. Each subagent should:
- Run the specific AWS CLI / SSM / curl commands needed
- Return a **summary** (5-10 lines max), not raw output
- Include specific error messages, timestamps, and status codes

Use the diagnostic procedures in [diagnostics.md](references/diagnostics.md) for the exact commands. Work top-down through the layers, but skip layers that clearly aren't relevant to the symptom.

**Layer order:**
1. Instance state (running? SSM reachable?)
2. Container health (Docker containers running? Traefik healthy?)
3. App health (specific app containers, compose status)
4. Recent logs (Docker logs for Traefik or specific app)
5. External reachability (curl through Cloudflare Tunnel)
6. Resource pressure (memory, disk — t4g.small has 2GB)

**AWS profile:** Use `AWS_PROFILE=appserver` (deployer) for all diagnostic commands. See [aws-access.md](references/aws-access.md) for role capabilities and escalation.

### Phase 2: Diagnosis

Based on subagent findings, determine:

1. **What is broken** — specific container, service, or component
2. **Root cause** — why it broke (OOM, config error, image pull failure, DNS issue, etc.)
3. **Layer** — which architectural layer is affected
4. **Severity** — operational (restart fixes it) vs. config/code bug vs. infrastructure issue

Consult [common-issues.md](references/common-issues.md) for known symptom-to-cause mappings.

**Immediate operational actions** (restart a stopped instance, restart a container) can be taken now to restore service. But if the root cause is a bug or config issue, a proper fix is still needed.

Report your diagnosis to the user before proceeding to Phase 3.

### Phase 3: Fix

Apply the fix:

1. If it's an operational issue (restart, start instance): use the CLI or SSM
2. If it's a code/config change: edit the files and deploy
3. If it's a terraform change: update the terraform files and run deploy

**IaC is truth.** If the fix involves infrastructure changes:
- The terraform files MUST be updated
- Changes MUST be applied via `./scripts/appserver.sh deploy` or `config push`
- Never make AWS changes that aren't reflected in the codebase

### Phase 4: Verify & Report

After the fix is applied:

1. **Re-check the original symptom** — verify the specific thing that was broken is now working
2. **Run status check** — `./scripts/appserver.sh status` to confirm overall health

**Always produce this output:**

```markdown
## Appserver Ops Report

**Status**: RESOLVED | MITIGATED | ESCALATED
**Root cause**: What actually broke and why
**Fix applied**: What changed (files, config, infra, operational action)
**Deployed**: Yes/No — whether config push/deploy was run
**Health check**: Containers running, resources OK

### Actions taken
- [List of specific actions]

### For the user
- [Any follow-up needed]
- [Specific guidance if the issue may recur]
```

**Status definitions:**
- **RESOLVED** — Root cause identified and fixed, health checks passing
- **MITIGATED** — Service restored but root cause fix is pending or partial
- **ESCALATED** — Cannot be fixed automatically (e.g., AWS outage, requires manual console action, needs admin IAM)

## Conventions

- `$PROJECT_ROOT` in reference files means the repository root (`/home/matthew/appserver`). Resolve it before running commands.

## Gotchas

- **SSM commands return async.** `send-command` returns immediately. You must `sleep 3` then `get-command-invocation` to read output. Forgetting this gives empty results.
- **Instance takes ~3 minutes after start.** If the instance was stopped, starting it is not enough — Docker and Traefik need time to boot. Don't report "service down" until SSM shows the instance online for 3+ minutes.
- **Config push is not atomic.** The SSM command downloads, extracts, and restarts Traefik. If it fails mid-way, Traefik may be down. Check SSM command output for which step failed.
- **`terraform output` needs init.** If terraform hasn't been initialized in this session, `terraform output` fails. Read values from `terraform.tfvars` directly or run init first.
- **The deployer profile may not be set.** If `AWS_PROFILE=appserver` doesn't work, the profile may not exist yet (init not run). Fall back to checking `aws configure list-profiles` first.
- **Cloudflare 403 vs app error.** Cloudflare 403 = missing CF-Access headers or expired service token. App-level errors come through as different status codes. Check response body to distinguish.
- **Docker logs may be verbose.** Always use `--since 10m` or `--tail 50` to scope log queries.
- **ARM architecture.** The instance is ARM (t4g.small/Graviton). Docker images must support `linux/arm64`. If an image pull works but container crashes, check architecture compatibility.
- **App secrets are on the instance.** `.env` files live at `/opt/appserver/apps/<name>/.env` on the instance, NOT in the repo. Use `app env` to view/set.
- **Traefik routes by Docker labels.** If an app is running but not reachable, check that the Docker Compose file has the correct Traefik labels and the container is on the `appserver` network.
- **First deploy uploads artifacts AFTER terraform.** On first deploy, the artifacts bucket is created by terraform, then artifacts are uploaded. If the instance bootstraps before artifacts are available, cloudflared may start from the S3 fallback binary.
- **Zone-wide WAF rules block appserver subdomains.** If another project (Rockport) has WAF custom rules on the same Cloudflare zone, they'll block appserver traffic unless scoped by hostname. Check Security → Events for "Block non-allowlisted paths" if you get 403 "you have been blocked."
- **SSL inside containers is unnecessary.** Traffic flow is Client → Cloudflare (TLS) → Tunnel (encrypted) → Traefik (:80) → Container (:80). Apps should serve HTTP only. If an app's nginx expects SSL certs and crashes, that's an app-level fix.
- **X-Forwarded-Proto must be preserved.** Traefik sets `X-Forwarded-Proto: https` (from Cloudflare). If an app's internal nginx overwrites this with `$scheme` (http), Django's `SECURE_SSL_REDIRECT` will 301-redirect API calls, silently breaking frontend features. Always check `docker exec APP curl -sv http://localhost/api/... 2>&1 | grep Location` if an app behaves unexpectedly.
- **Entrypoint errors may be silently swallowed.** Many Docker entrypoints pipe DB wait checks through `2>/dev/null`. If the check fails for a non-DB reason (missing env var, import error), logs just show "Waiting for database..." with no hint of the real error. Test the check command manually with `docker exec` to see the actual error.
- **SSM TimeoutSeconds minimum is 30.** Any `ssm_run` call with a timeout below 30 will fail with `ParamValidation`. All timeouts in the CLI must be >= 30.
- **Destroy keeps AppserverAdmin policy.** The bootstrap cleanup intentionally preserves the AppserverAdmin IAM policy so that `init` can re-bootstrap without needing root/admin access to recreate it.
- **Cookie app version upgrades.** To upgrade Cookie: `app env cookie COOKIE_VERSION=X.Y.Z` then `app deploy cookie`. The deploy pulls the new image and restarts. Coordinate with the Cookie repo's CD workflow — wait for the GitHub Actions CD run to complete before deploying.

## Rules

1. **Subagents for I/O, main context for decisions.** All AWS CLI output, log dumps, and curl responses go through subagents. The main context only sees summaries.

2. **Deployer profile by default.** Use `AWS_PROFILE=appserver` for diagnostics and operations. Only escalate to admin (unset AWS_PROFILE) if the issue involves IAM policy changes or admin-only operations. See [aws-access.md](references/aws-access.md).

3. **IaC must match reality.** If you change anything on AWS, the terraform and project code must reflect it. Never let code and infrastructure diverge.

4. **Phase 4 is mandatory.** Every invocation produces the structured ops report, whether the issue was a simple restart or a complex multi-file fix.

5. **Use the CLI when possible.** `appserver.sh` wraps many operations. Prefer it over raw AWS CLI for standard tasks (status, deploy, app management).
