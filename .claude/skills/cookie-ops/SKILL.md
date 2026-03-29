---
name: cookie-ops
description: "Diagnose, manage, and troubleshoot the Cookie app deployed on appserver. Use when the user mentions cookie, device pairing, passkeys, recipe features, cookie version upgrades, cookie logs, cookie cron jobs, or cookie admin commands. Also triggers for: 'pair my device', 'upgrade cookie', 'cookie is down', 'check cookie logs'."
user-invocable: true
argument-hint: "[symptom, action, or question about Cookie]"
allowed-tools: "Read, Grep, Glob, Bash, Agent"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Purpose

Manage and troubleshoot the Cookie app (Django recipe manager with passkey auth) running on appserver. Cookie runs as a Docker Compose stack (`cookie-web` + `cookie-db`) behind Traefik.

Input can be:
- Symptom descriptions ("cookie is down", "device pairing broken", "passkeys not working")
- Operational requests ("upgrade cookie to v1.14.0", "check cookie logs", "run cleanup")
- Health checks ("is cookie healthy?", "check the cron jobs")
- Version management ("what version is running?", "deploy latest cookie")

## Quick Reference

| Task | Command |
|------|---------|
| Deploy new version | `app env cookie COOKIE_VERSION=X.Y.Z` then `app deploy cookie` |
| Check status | `cookie_admin status --json` via SSM |
| View logs | `./scripts/appserver.sh logs cookie` |
| Security audit | `cookie_admin audit --json` via SSM |
| List users | `cookie_admin list-users --json` via SSM |
| Run cleanup | `cleanup_device_codes` / `cleanup_sessions` / `cleanup_search_images` via SSM |

## Workflow

### For health checks and diagnostics

1. **Check app health** via subagent — run `cookie_admin status --json` for structured overview
2. **Check logs** if symptoms reported — scope with `--since 10m` or `--tail 50`
3. **Diagnose** — see [common-issues.md](references/common-issues.md) for symptom-to-cause mapping
4. **Fix or escalate** — app-level fixes here; infrastructure issues → delegate to `/appserver-ops`

### For version upgrades

1. Verify the image exists on GHCR (CD workflow must be complete)
2. `./scripts/appserver.sh app env cookie COOKIE_VERSION=X.Y.Z`
3. `./scripts/appserver.sh app deploy cookie`
4. **Watch for crash loops** — check container status within 30 seconds
5. If crash-looping, roll back immediately: set previous version and redeploy
6. Run `cookie_admin status --json` to verify health post-deploy

### For user/auth management

Use `cookie_admin` subcommands via SSM — see [admin-commands.md](references/admin-commands.md).

## Conventions

- All SSM commands use `AWS_PROFILE=appserver` (deployer profile)
- Always use `--json` flag with `cookie_admin` subcommands for structured output
- Scope log queries: `--since 10m` or `--tail 50` to avoid noise
- Cookie containers: `cookie-web-1` (app), `cookie-db` (postgres)
- App secrets live at `/opt/appserver/apps/cookie/.env` on the instance — use `app env` CLI

## When to Escalate to /appserver-ops

Delegate to the infrastructure skill when the issue is:
- Instance not running or SSM unreachable
- Traefik not routing (404 from Traefik, not from Cookie)
- Cloudflare Tunnel down (all subdomains affected, not just cookie)
- Resource pressure (OOM, disk full) affecting multiple services
- Security group or IAM issues

## Gotchas

- **Wait for CD before deploying.** Cookie images are built by GitHub Actions CD on version tags. If `app deploy` fails with "manifest not found", the workflow hasn't finished. Check the Cookie repo's Actions tab.
- **Watch for crash loops after upgrades.** If cookie-web restarts repeatedly with exit code 0 and no errors, suspect entrypoint process supervision bugs. Roll back immediately.
- **Cron logs appear in `docker logs`.** All three cron jobs redirect to `/proc/1/fd/1`. Check with: `docker logs cookie-web-1 --since 2h 2>&1 | grep -i cleanup`
- **Device code issues have layers.** Check in order: JS executing on client (old browsers?), POST creating code (201?), poll returning status (500?), authorization succeeding (200?). Each step can fail independently.
- **`cookie_admin status --json` is the single best diagnostic.** It covers DB, migrations, auth config, user counts, device code state, cron job health, and AI config in one call.
- **Entrypoint errors may be swallowed.** DB wait loops pipe through `2>/dev/null`. If logs just show "Waiting for database..." but DB is healthy, test the check command manually with `docker exec`.
- **Passkeys need correct RP ID.** `WEBAUTHN_RP_ID` must be `matthewdeaves.com` (parent domain). Check `cookie_admin status --json` → `webauthn.rp_id`.
- **First user is auto-admin.** The first person to register at `/register` gets promoted to admin automatically.

## Report Format

For diagnostic invocations, produce:

```markdown
## Cookie Ops Report

**Status**: HEALTHY | DEGRADED | DOWN
**Version**: X.Y.Z
**Issue** (if any): What's wrong
**Fix applied** (if any): What changed
**Cron health**: All running / [specific job] not firing

### Details
- [Findings or actions taken]
```
