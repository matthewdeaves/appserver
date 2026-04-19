# Cookie Common Issues

Symptom-to-cause mappings for Cookie app issues. For infrastructure-level issues (instance down, Traefik broken, tunnel disconnected), see `/appserver-ops`.

## Passkey Registration Fails

**Symptoms:** User cannot register a passkey, browser shows WebAuthn error
**Causes:**
1. `WEBAUTHN_RP_ID` not set or wrong — must be `matthewdeaves.com` (parent domain)
2. User accessing via IP or wrong domain — WebAuthn requires HTTPS + correct origin
3. Browser doesn't support WebAuthn (very old browsers)
**Check:** `cookie_admin status --json` — verify `webauthn.rp_id` is `matthewdeaves.com`

## Device Code Pairing Not Working

**Symptoms:** 6-char codes not accepted, pairing page blank, iPad shows code but never logs in

**Check in order (each step can fail independently):**

1. **Page loads but button does nothing** — JavaScript not executing on old browsers (Safari 9/10 on iOS 9-10). Fixed in v1.12.0 with ES5-compatible legacy JS.
2. **POST to create code fails** — Check `docker logs cookie-web --since 10m 2>&1 | grep 'device/code'` for non-201 responses.
3. **Poll returns 500** — Two known bugs (both fixed):
   - `FeatureNotSupported: FOR UPDATE cannot be applied to nullable outer join` (fixed v1.12.1)
   - `MultipleObjectsReturned` from stale codes accumulating (fixed v1.13.0)
4. **Authorization succeeds but iPad doesn't see it** — Poll endpoint crashing before returning "authorized" status. Check for 500s in logs.

**Quick check:** `cookie_admin status --json` → `device_codes.pending` and `device_codes.stale_expired`
**Cleanup:** `cleanup_device_codes` via SSM (runs hourly via cron in v1.13.0+)

## Version Upgrade Crash Loop

**Symptoms:** Cookie container restarts repeatedly after version upgrade, exit code 0, no errors in logs

**Causes (in order of likelihood):**
1. **Image not ready** — CD workflow hasn't finished building. Check Cookie repo Actions tab.
2. **Cron daemon bug** — Entrypoint uses `cron &` instead of `cron -f &`, causing `wait -n` to trigger shutdown (fixed in v1.13.0 re-release).
3. **New env vars required** — Check release notes for new required configuration.
4. **Migration failure** — Check `docker logs cookie-web --tail 50` for migration errors.

**Immediate fix:** Roll back: revert version in `docker-compose.yml`, `config push`, then `app deploy cookie`
**Key lesson:** Always check container status within 30 seconds of deploying a new version.

## Cron Jobs Not Firing

**Symptoms:** `maintenance.<job>` in `cookie_admin status --json` is the literal string `"never run"` for longer than the job's schedule. (After a successful run the value becomes an object with a `time` key, e.g. `{"time": "2026-04-18T11:00:02Z", "deleted": 0, ...}`.) Keys are `device_code_cleanup`, `session_cleanup`, `search_image_cleanup`.

**Causes:**
1. Cron daemon not running — check `docker exec cookie-web pgrep -a cron`
2. Crontab missing — check `docker exec cookie-web cat /etc/cron.d/cookie-cleanup`
3. Container restarted recently — cron jobs haven't hit their next schedule yet (normal after deploy)

**Fix:** If cron process is missing, this is a Cookie image bug (entrypoint issue). Roll back to a known-good version.

## Wrong Auth Mode / UI

**Symptoms:** Passkey mode shows home mode UI, or features don't work as expected

**Cause:** Django's `SECURE_SSL_REDIRECT` was `true` while running behind a multi-layer proxy (Cloudflare → Tunnel → Traefik → nginx). Internal nginx overwrites `X-Forwarded-Proto` with `$scheme` (http), causing Django to 301-redirect all API calls.
**Check:** `docker exec cookie-web curl -sv http://localhost/api/system/health/ 2>&1 | grep Location` — if it redirects to https, the header is wrong.
**Fix:** Cookie v1.22.1+ defaults `SECURE_SSL_REDIRECT=false` since Cloudflare handles HTTPS at the edge. If running an older version, set `SECURE_SSL_REDIRECT=false` in .env.

## Slow AI Features

**Symptoms:** Recipe discover, scale, or AI features take too long
**Cause:** OpenRouter LLM calls (network + inference time)
**Check:** `cookie_admin status --json` → `openrouter.configured` and `openrouter.model`
**Note:** Since v1.11.0, discover makes parallel LLM calls. If still slow, bottleneck is upstream.

## Stale Search Images

**Symptoms:** Disk usage growing from cached recipe search images
**Check:** `cleanup_search_images --dry-run` via SSM
**Fix:** `cleanup_search_images --days 7` via SSM. Automated daily at 3:30 AM in v1.13.0+.

## Unexpected User Registrations

**Symptoms:** Unknown users in `cookie_admin list-users`
**Check:** `cookie_admin audit --json --lines 100` — look for registration events
**Response:**
1. Deactivate suspicious accounts: `cookie_admin deactivate USERNAME`
2. Check Cloudflare Access is enforcing auth (302 for unauthenticated)
3. Review if registration endpoint is properly protected

## Database Issues

**Symptoms:** "Waiting for database..." in logs but cookie-db is healthy
**Cause:** Entrypoint DB wait check failing for non-DB reasons (missing env var, import error). The error is swallowed by `2>/dev/null`.
**Check:** `docker exec cookie-web python -c "import django; django.setup()"` to see the actual error.
