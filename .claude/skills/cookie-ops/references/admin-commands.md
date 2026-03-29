# Cookie Admin Commands

All commands run inside the `cookie-web-1` container via SSM. Use `AWS_PROFILE=appserver`.

## SSM Pattern

```bash
REGION=$(grep '^region' $PROJECT_ROOT/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
INSTANCE_ID=$(cd $PROJECT_ROOT/terraform && terraform output -raw instance_id 2>/dev/null)

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["docker exec cookie-web-1 python manage.py COMMAND"]}' \
  --query 'Command.CommandId' --output text --region "$REGION")

sleep 3

aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

## cookie_admin Subcommands

All support `--json` for structured output. Always use `--json` when running via SSM.

### status

```bash
docker exec cookie-web-1 python manage.py cookie_admin status --json
```

Returns:
```json
{
  "ok": true,
  "auth_mode": "passkey",
  "database": "connected",
  "migrations": "up to date",
  "users": {"total": 2, "active": 2, "admins": 1},
  "passkeys": 2,
  "device_codes": {"pending": 0, "stale_expired": 0},
  "openrouter": {"configured": true, "source": "env", "model": "anthropic/claude-haiku-4.5"},
  "webauthn": {"rp_id": "matthewdeaves.com", "rp_name": "Cookie"},
  "maintenance": {
    "cleanup_device_codes": {"last_run": "2026-03-29T08:00:00Z", "schedule": "hourly"},
    "cleanup_sessions": {"last_run": "2026-03-29T03:15:00Z", "schedule": "daily 3:15 AM"},
    "cleanup_search_images": {"last_run": "2026-03-29T03:30:00Z", "schedule": "daily 3:30 AM"}
  }
}
```

**Best single diagnostic command.** Covers DB, migrations, auth, users, device codes, cron health, and AI config.

### audit

```bash
docker exec cookie-web-1 python manage.py cookie_admin audit --json
# Optional: --lines N (default 50)
```

Returns recent security events: `registration`, `passkey_login`, `device_code_authorized`.

Each event includes timestamp, type, username/credential ID, and relevant metadata.

### list-users

```bash
docker exec cookie-web-1 python manage.py cookie_admin list-users --json
# Optional: --active-only, --admins-only
```

Returns all user accounts with activity status.

### User Management

```bash
# Promote to admin
docker exec cookie-web-1 python manage.py cookie_admin promote USERNAME --json

# Demote from admin
docker exec cookie-web-1 python manage.py cookie_admin demote USERNAME --json

# Deactivate account
docker exec cookie-web-1 python manage.py cookie_admin deactivate USERNAME --json

# Reactivate account
docker exec cookie-web-1 python manage.py cookie_admin activate USERNAME --json
```

## Cleanup Commands

### cleanup_device_codes

```bash
docker exec cookie-web-1 python manage.py cleanup_device_codes --dry-run
```

Purges expired/invalidated device pairing codes. Runs hourly via cron. Remove `--dry-run` to execute.

### cleanup_sessions

```bash
docker exec cookie-web-1 python manage.py cleanup_sessions --dry-run
```

Cleans up expired Django sessions. Runs daily at 3:15 AM UTC via cron.

### cleanup_search_images

```bash
docker exec cookie-web-1 python manage.py cleanup_search_images --dry-run
# Optional: --days N (default 30)
```

Removes cached recipe search images not accessed in N days. Runs daily at 3:30 AM UTC via cron.

## Django Built-in Commands

### Security check

```bash
docker exec cookie-web-1 python manage.py check --deploy
```

Runs Django's production security checklist (HSTS, CSRF, session security). Read-only, safe for production.

### Migration status

```bash
docker exec cookie-web-1 python manage.py showmigrations
```

Shows all migrations. `[X]` = applied, `[ ]` = pending. Pending migrations run automatically on container start.

## Cron Health Check

```bash
# Check if cron daemon is running
docker exec cookie-web-1 pgrep -a cron

# Check crontab
docker exec cookie-web-1 cat /etc/cron.d/cookie-cron

# Check recent cron output in logs
docker logs cookie-web-1 --since 2h 2>&1 | grep -i cleanup
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
docker exec cookie-web-1 awk '$9 >= 400' /var/log/nginx/access.log | tail -20

# Error log
docker exec cookie-web-1 cat /var/log/nginx/error.log | tail -20
```
