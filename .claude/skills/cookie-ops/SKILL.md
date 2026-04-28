---
name: cookie-ops
description: "Diagnose, manage, and troubleshoot the Cookie app on appserver. Use when: cookie health, device pairing, passkeys, version upgrades, cookie logs, cron jobs, cookie admin commands, 'cookie is down'."
user-invocable: true
argument-hint: "[symptom, action, or question about Cookie]"
allowed-tools: "Read, Grep, Glob, Bash, Agent"
effort: high
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

## Scripts

Helper scripts in `scripts/` — run from the appserver repo root:

| Script | Purpose |
|--------|---------|
| `scripts/quick-health.sh` | Single SSM call: cookie_admin status + running version + user list → JSON |
| `scripts/check-crons.sh` | SSM: supercronic process, /app/crontab contents, recent cron output |

## Quick Reference

| Task | Command |
|------|---------|
| Deploy new version | Update version in `docker-compose.yml`, `config push`, `app deploy cookie` |
| Check status | `python manage.py cookie_admin status --json` via SSM |
| Running version | `docker ps --filter name=cookie-web --format '{{.Image}}'` (not in `status --json` since v1.42.0) |
| View logs | `./scripts/appserver.sh logs cookie` |
| Security audit | `python manage.py cookie_admin audit --json` via SSM |
| List users | `python manage.py cookie_admin list-users --json` via SSM |
| Set OpenRouter key | `cookie_admin set-api-key --stdin --json` via SSM (passkey-mode CLI-only) |
| Set default model | `cookie_admin set-default-model MODEL_ID --json` via SSM |
| Manage AI prompts | `cookie_admin prompts {list,show,set}` via SSM |
| Manage search sources | `cookie_admin sources {list,toggle,test,repair,...}` via SSM |
| Show/set AI quotas | `cookie_admin quota {show,set}` via SSM |
| Rename a profile | `cookie_admin rename TARGET --name NEW_NAME` via SSM |
| Grant AI exemption | `cookie_admin set-unlimited USERNAME --json` / `remove-unlimited USERNAME --json` via SSM |
| Factory reset | `cookie_admin reset --confirm --json` via SSM (HTTP endpoint is 404 in passkey mode, HomeOnlyAuth) |
| Run cleanup | `python manage.py cleanup_device_codes` / `cleanup_sessions` / `cleanup_search_images` via SSM |

## Workflow

### For health checks and diagnostics

1. **Check app health** via subagent — run `cookie_admin status --json` for structured overview
2. **Check logs** if symptoms reported — scope with `--since 10m` or `--tail 50`
3. **Diagnose** — see [common-issues.md](references/common-issues.md) for symptom-to-cause mapping
4. **Fix or escalate** — app-level fixes here; infrastructure issues → delegate to `/appserver-ops`

### For version upgrades

1. Verify the image exists on GHCR (CD workflow must be complete)
2. Update the image tag default in `config/apps/cookie/docker-compose.yml` (the `${COOKIE_VERSION:-X.Y.Z}` default on the `image:` line)
3. `./scripts/appserver.sh config push` then `./scripts/appserver.sh app deploy cookie`
4. **Watch for crash loops** — check container status within 30 seconds
5. If crash-looping, roll back: revert compose file, `config push`, `app deploy`
6. Run `python manage.py cookie_admin status --json` to verify health post-deploy

**Important:** The version is pinned in `docker-compose.yml` only (single source of truth). Do NOT set `COOKIE_VERSION` in the instance `.env` — the compose default is authoritative.

### For user/auth management

Use `cookie_admin` subcommands via SSM — see [admin-commands.md](references/admin-commands.md).

## Conventions

- All SSM commands use `AWS_PROFILE=appserver` (deployer profile)
- Always use `--json` flag with `cookie_admin` subcommands for structured output
- Scope log queries: `--since 10m` or `--tail 50` to avoid noise
- Cookie containers: `cookie-web` (app), `cookie-db` (postgres)
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
- **`python manage.py cookie_admin status --json` is the single best diagnostic.** It covers DB, migrations, auth config, user counts, device code state, cron job health, and AI config in one call.
- **Entrypoint errors may be swallowed.** DB wait loops pipe through `2>/dev/null`. If logs just show "Waiting for database..." but DB is healthy, test the check command manually with `docker exec`.
- **Passkeys need correct RP ID.** `WEBAUTHN_RP_ID` must be `matthewdeaves.com` (parent domain). Check `cookie_admin status --json` → `webauthn.rp_id`.
- **No admin tier (v1.43.0).** `is_staff`, `AdminAuth`, and the `promote` / `demote` subcommands are gone. All authenticated users are peers. Mode-gated operations (admin-style settings, factory reset, prompts, sources, quotas) run via `cookie_admin` CLI in passkey mode, or via the home-mode web admin UI. Per-user privilege that remains is `Profile.unlimited_ai` (AI-quota exemption) via `cookie_admin set-unlimited` / `remove-unlimited`.
- **`SECURE_SSL_REDIRECT` must be false behind proxy.** Cookie v1.22.1+ defaults to `false`. Cloudflare handles HTTPS at the edge; enabling this in Django causes infinite 301 redirect loops.
- **Admin UI is passkey-mode gated (v1.42.0+).** In passkey mode, the web admin sections for API key, default model, prompts, sources, AI quotas, and danger-zone reset are invisible in both the legacy and SPA frontends. Change these via `cookie_admin` CLI only. Home mode retains the full web admin UI.
- **Running version is NOT in `status --json` (v1.42.0+).** The `/api/system/mode/` endpoint no longer exposes version either (fingerprint fix). Read it from the image tag: `docker ps --filter name=cookie-web --format '{{.Image}}'`.

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
