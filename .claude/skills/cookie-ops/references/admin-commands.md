# Cookie Admin Commands

All commands run inside the `cookie-web` container via SSM. Use `AWS_PROFILE=appserver`.

## SSM Pattern

```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
INSTANCE_ID=$(cd $PROJECT_ROOT/terraform && terraform output -raw instance_id 2>/dev/null)

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker exec cookie-web python manage.py COMMAND"]}' \
  --query 'Command.CommandId' --output text --region "$REGION")

sleep 3

aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

## First-Time Setup (New Deployment)

**v1.43.0: there is no admin tier anymore.** `is_staff` was retired; the `promote` / `demote` subcommands are gone. In passkey mode all authenticated users are peers; admin-only operations run via the CLI itself (e.g. `cookie_admin reset`, `cookie_admin set-api-key`, `cookie_admin prompts set`).

Privilege that remains is `Profile.unlimited_ai` — grants AI-quota exemption only. Set it with:

```bash
docker exec cookie-web python manage.py cookie_admin set-unlimited USERNAME --json
docker exec cookie-web python manage.py cookie_admin remove-unlimited USERNAME --json
```

## cookie_admin Subcommands

All support `--json` for structured output. Always use `--json` when running via SSM.

**Mode gating (v1.42.0+):** User-lifecycle subcommands (`create-user`, `delete-user`, `activate`, `deactivate`, `create-session`) require `AUTH_MODE=passkey`. Other subcommands work in either mode. The CLI returns an error if you invoke a passkey-only subcommand in home mode.

**v1.43.0 deletions:** `promote`, `demote` subcommands removed. `--admin` flag on `create-user` removed. `--admins-only` flag on `list-users` removed. `is_admin` field removed from `status`, `list-users`, and `audit` JSON output (replaced with `unlimited_ai`).

**Running version:** `status --json` does NOT include the running version (removed in v1.42.0 as a fingerprinting fix). Get it via `docker ps --filter name=cookie-web --format '{{.Image}}'`.

### status

```bash
docker exec cookie-web python manage.py cookie_admin status --json
```

Returns:
```json
{
  "ok": true,
  "auth_mode": "passkey",
  "database": "ok",
  "migrations": "up to date",
  "users": {"total": 2, "active": 2},
  "passkeys": 2,
  "device_codes": {"pending": 0, "stale_expired": 0},
  "openrouter": {"configured": true, "source": "env", "model": "anthropic/claude-haiku-4.5"},
  "webauthn": {"rp_id": "matthewdeaves.com", "rp_name": "Cookie"},
  "maintenance": {
    "device_code_cleanup": {"time": "2026-04-18T11:00:02Z", "deleted": 0, "remaining": 0, "expired": 0, "invalidated": 0, "consumed": 0},
    "session_cleanup": "never run",
    "search_image_cleanup": "never run"
  },
  "cache": {"status": "healthy", "cache_stats": {"total": 0, "success": 0, "pending": 0, "failed": 0, "success_rate": "N/A"}}
}
```

Each `maintenance.<job>` is either the literal string `"never run"` (cron hasn't fired yet) or an object with `time` plus job-specific counters.

**Best single diagnostic command.** Covers DB, migrations, auth, users, device codes, cron health, and AI config.

### audit

```bash
docker exec cookie-web python manage.py cookie_admin audit --json
# Optional: --lines N (default 50)
```

Returns recent security events: `registration`, `passkey_login`, `device_code_authorized`.

Each event includes timestamp, type, username/credential ID, and relevant metadata.

### list-users

```bash
docker exec cookie-web python manage.py cookie_admin list-users --json
# Optional: --active-only
```

Returns all user accounts with activity status. Each entry includes `username`, `user_id`, `passkeys`, `is_active`, `unlimited_ai`, `date_joined` (v1.43.0: `is_admin` removed).

### Create / Delete Users

```bash
# Create a user (no passkey, headless — for testing/automation)
docker exec cookie-web python manage.py cookie_admin create-user USERNAME --json

# Delete a user and all associated data (profile, sessions, etc.)
docker exec cookie-web python manage.py cookie_admin delete-user USERNAME --json
```

v1.43.0: the `--admin` flag was removed from `create-user`. All users are created non-privileged; there is no admin tier at the account level. Users created via `create-user` have no passkey and an unusable password — they can only be accessed via `create-session`. The pentest bootstrap uses this to create test users, then deletes them after the run.

### User Activation

```bash
# Deactivate account
docker exec cookie-web python manage.py cookie_admin deactivate USERNAME --json

# Reactivate account
docker exec cookie-web python manage.py cookie_admin activate USERNAME --json
```

v1.43.0: `promote` / `demote` removed (is_staff retired). Grant AI-quota exemption via `set-unlimited` below — that is the only per-user privilege that remains.

### AI Quota Management

```bash
# Grant unlimited AI usage
docker exec cookie-web python manage.py cookie_admin set-unlimited USERNAME --json

# Revoke unlimited AI usage
docker exec cookie-web python manage.py cookie_admin remove-unlimited USERNAME --json

# View AI usage stats (all users or specific user)
docker exec cookie-web python manage.py cookie_admin usage --json
docker exec cookie-web python manage.py cookie_admin usage --username USERNAME --json
```

Per-feature daily usage tracked for: remix, remix_suggestions, scale, tips, discover, timer.

### create-session (pentest/automation)

```bash
docker exec cookie-web python manage.py cookie_admin create-session USERNAME --json
# Optional: --ttl N (default 3600 = 1 hour, range 60-86400)
```

Creates a Django session for the specified user without WebAuthn authentication.
Returns the session key for use in automated testing (e.g., pentest SSRF tests).
Session is short-lived (default 1 hour) and logged to the security logger.

### Factory reset

```bash
docker exec cookie-web python manage.py cookie_admin reset --confirm --json
```

Deletes all user data and re-seeds defaults. `--confirm` is required when using `--json` (prevents accidental non-interactive data loss). This is the only way to factory-reset in passkey mode — the `/api/system/reset/` HTTP endpoint returns 404 (HomeOnlyAuth).

### AI Configuration (v1.42.0+)

In passkey mode the web UI for these settings is removed; CLI is the only way to change them. In home mode the web admin remains authoritative, but the CLI still works.

```bash
# Set the OpenRouter API key (prefer --stdin so the key never enters shell history)
echo -n "$OPENROUTER_KEY" | docker exec -i cookie-web python manage.py cookie_admin set-api-key --stdin --json

# Validate a key WITHOUT saving (tests the OpenRouter endpoint)
echo -n "$OPENROUTER_KEY" | docker exec -i cookie-web python manage.py cookie_admin test-api-key --stdin --json

# Set the default AI model id
docker exec cookie-web python manage.py cookie_admin set-default-model anthropic/claude-haiku-4.5 --json
```

**API key precedence:** `OPENROUTER_API_KEY` env var (set in `.env`) wins over the DB-stored key. `status --json → openrouter.source` shows which one is active (`env`, `db`, or `none`).

### AI Prompts (v1.42.0+)

```bash
# List all AI prompt types
docker exec cookie-web python manage.py cookie_admin prompts list --json

# Show one prompt by type
docker exec cookie-web python manage.py cookie_admin prompts show PROMPT_TYPE --json

# Update a prompt's fields (content is loaded from a file path)
docker exec cookie-web python manage.py cookie_admin prompts set PROMPT_TYPE --content-file /path/to/prompt.txt --json
```

Use `prompts list --json` first to discover valid `PROMPT_TYPE` values. Content must come from a file (not inline) to keep large prompts out of shell history and argv.

### Search Sources (v1.42.0+)

```bash
# List all search sources
docker exec cookie-web python manage.py cookie_admin sources list --json

# Toggle one source on/off
docker exec cookie-web python manage.py cookie_admin sources toggle SOURCE_ID --json

# Set every source's enabled state at once
docker exec cookie-web python manage.py cookie_admin sources toggle-all --enabled true --json

# Overwrite a source's CSS selector
docker exec cookie-web python manage.py cookie_admin sources set-selector SOURCE_ID --selector '.recipe-body' --json

# Health-check one source (or all)
docker exec cookie-web python manage.py cookie_admin sources test [SOURCE_ID] --json

# AI-assisted selector regeneration (requires OpenRouter API key)
docker exec cookie-web python manage.py cookie_admin sources repair SOURCE_ID --json
```

### AI Quotas (v1.42.0+)

```bash
# Show all six daily limits (remix, remix_suggestions, scale, tips, discover, timer)
docker exec cookie-web python manage.py cookie_admin quota show --json

# Set one daily limit
docker exec cookie-web python manage.py cookie_admin quota set FEATURE LIMIT --json
# e.g.: quota set discover 50 --json
```

Use `set-unlimited USERNAME` / `remove-unlimited USERNAME` for per-user overrides on top of these global defaults.

### Rename a profile (v1.42.0+)

```bash
# Passkey mode: target is user_id or username
docker exec cookie-web python manage.py cookie_admin rename pk_XXXXXXXX --name "New Name" --json

# Home mode: target is profile_id
docker exec cookie-web python manage.py cookie_admin rename 42 --name "Family Cook" --json
```

## Cleanup Commands

### cleanup_device_codes

```bash
docker exec cookie-web python manage.py cleanup_device_codes --dry-run
```

Purges expired/invalidated device pairing codes. Runs hourly via cron. Remove `--dry-run` to execute.

### cleanup_sessions

```bash
docker exec cookie-web python manage.py cleanup_sessions --dry-run
```

Cleans up expired Django sessions. Runs daily at 3:15 AM UTC via cron.

### cleanup_search_images

```bash
docker exec cookie-web python manage.py cleanup_search_images --dry-run
# Optional: --days N (default 30)
```

Removes cached recipe search images not accessed in N days. Runs daily at 3:30 AM UTC via cron.

## Django Built-in Commands

### Security check

```bash
docker exec cookie-web python manage.py check --deploy
```

Runs Django's production security checklist (HSTS, CSRF, session security). Read-only, safe for production.

### Migration status

```bash
docker exec cookie-web python manage.py showmigrations
```

Shows all migrations. `[X]` = applied, `[ ]` = pending. Pending migrations run automatically on container start.

## Cron Health Check

Cookie uses **supercronic** (not system cron). The crontab is at `/app/crontab` inside the container.

```bash
# Check if supercronic is running
docker exec cookie-web pgrep -a supercronic

# Check crontab
docker exec cookie-web cat /app/crontab

# Check recent cron output in logs
docker logs cookie-web --since 2h 2>&1 | grep -i cleanup
```

Three cron jobs configured:
| Schedule | Command | Purpose |
|----------|---------|---------|
| `0 * * * *` | `cleanup_device_codes` | Purge expired device codes |
| `15 3 * * *` | `cleanup_sessions` | Clean expired sessions |
| `30 3 * * *` | `cleanup_search_images` | Remove stale cached images |

All output redirects to `/proc/1/fd/1` (container stdout) so it appears in `docker logs`.

## Nginx Logs

```bash
# 4xx/5xx errors
docker exec cookie-web awk '$9 >= 400' /var/log/nginx/access.log | tail -20

# Error log
docker exec cookie-web cat /var/log/nginx/error.log | tail -20
```
