# Common Issues

Known symptom-to-cause mappings for appserver infrastructure. Organized by symptom category.

## Connection Failures

### HTTP 403 "Sorry, you have been blocked" (Cloudflare WAF)
**Symptoms:** All requests to any appserver subdomain return "Sorry, you have been blocked"
**Cause:** A zone-wide Cloudflare WAF rule from another project (e.g. Rockport's path allowlist) is blocking requests. WAF custom rules apply to the entire zone unless host-scoped.
**Check:** Security → Events in the Cloudflare dashboard. Look for the Ray ID in the error page. The event will show which rule blocked it (e.g. "Block non-allowlisted paths" from another project's WAF ruleset).
**Fix:** Scope the blocking WAF rule to its own subdomain only, e.g. add `(http.host eq "llm.matthewdeaves.com")` to the rule expression so it doesn't affect other subdomains.
**Key lesson:** WAF custom rulesets are zone-wide by default. Any project sharing the Cloudflare zone must scope its WAF rules by hostname.

### HTTP 403 from Cloudflare Access
**Symptoms:** All requests return 403, "Access denied" page
**Cause:** Missing or invalid CF-Access-Client-Id / CF-Access-Client-Secret headers
**Check:** Are headers being sent? Has the service token been rotated in Terraform without updating clients?
**Fix:** Verify token values match `terraform output cf_access_client_id` and `cf_access_client_secret`

### Connection timeout / refused
**Symptoms:** Requests hang or get connection refused
**Causes (in order of likelihood):**
1. Instance stopped (most common) — check instance state
2. Cloudflared tunnel not running — check `systemctl status cloudflared` via SSM
3. Traefik not running — check Traefik container
4. Instance still bootstrapping after start (~3 min)
**Fix:** Start instance, wait for services to come up

### HTTP 502 Bad Gateway
**Symptoms:** Intermittent 502s through the tunnel
**Cause:** App container crashed/restarting, Traefik routing to dead container
**Check:** `docker ps` to see container health, `docker compose logs` for the app

### HTTP 404 from Traefik
**Symptoms:** App subdomain returns 404
**Causes:**
1. App container not running (Traefik has no backend)
2. Docker labels missing or wrong Host rule in docker-compose.yml
3. Container not on the `appserver` Docker network
**Check:** `docker ps` for running containers, inspect Traefik labels

## Container Issues

### App container won't start
**Symptoms:** `docker compose up` exits immediately or restart loop
**Common causes:**
1. Image architecture mismatch (needs linux/arm64 for Graviton)
2. Missing .env file or required environment variables
3. Database connection failure (if app needs DB)
4. Port conflict with another container
5. SSL certificates expected but not mounted (nginx crashes with `[emerg] cannot load certificate`)
6. Entrypoint DB wait loop failing for non-DB reasons (e.g. missing `DJANGO_SETTINGS_MODULE` — the error is swallowed by `2>/dev/null`, logs just show "Waiting for database..." forever)
**Check:** `docker compose logs APP` for the startup error. If the logs show a DB wait loop but the DB is healthy, the issue may be in the entrypoint script, not the database.
**SSL note:** Containers behind Cloudflare Tunnel + Traefik should NOT use SSL internally. TLS is terminated at Cloudflare. If nginx expects certs at `/etc/nginx/ssl/`, the app needs to be configured for HTTP-only mode. This is an app-level fix, not an appserver fix.

### App works but shows wrong behavior (e.g. wrong auth mode)
**Symptoms:** App is running and reachable but features don't work as expected (e.g. passkey mode shows home mode UI)
**Cause:** Internal nginx overwriting `X-Forwarded-Proto` header with `$scheme` (which is `http` behind Traefik). Django's `SECURE_SSL_REDIRECT` then issues 301 redirects on API calls, breaking frontend functionality.
**Check:** `docker exec APP curl -sv http://localhost/api/endpoint/ 2>&1 | grep Location` — if it redirects to `https://localhost/...`, the proto header is wrong.
**Fix:** App's nginx config must pass through `X-Forwarded-Proto` from the upstream proxy rather than overwriting it. Alternatively, set `SECURE_SSL_REDIRECT=false` in the app's .env.
**Key lesson:** The traffic flow is Client → Cloudflare (HTTPS) → Tunnel → Traefik (HTTP, sets X-Forwarded-Proto: https) → nginx (HTTP) → app. Every layer must preserve the proto header, not overwrite it.

### App container OOM killed
**Symptoms:** Container suddenly stops, `docker inspect` shows OOMKilled: true
**Cause:** t4g.small has 2GB RAM total. Traefik + cloudflared + app containers share this
**Check:** `docker stats --no-stream` for memory usage, `dmesg | grep -i oom`
**Fix:** Add `mem_limit` to docker-compose.yml, optimize app memory usage

### Image pull failure
**Symptoms:** `docker compose pull` fails, "manifest not found" or "no matching manifest for linux/arm64"
**Cause:** Docker image doesn't publish ARM64 variant
**Fix:** Build and publish a multi-arch image including linux/arm64

### Container running but app unreachable
**Symptoms:** Container shows as running, but HTTP requests to subdomain fail
**Causes:**
1. Traefik labels missing or incorrect in docker-compose.yml
2. Container not on the `appserver` network
3. App listening on wrong port (doesn't match Traefik loadbalancer.server.port label)
**Check:** Compare docker-compose.yml labels against the Traefik label requirements in CLAUDE.md

## Traefik Issues

### Traefik health check failing
**Symptoms:** `traefik healthcheck --ping` returns error
**Cause:** Traefik config error or container resource pressure
**Check:** `docker logs traefik --tail 50` for config errors
**Fix:** `./scripts/appserver.sh config push` to re-push clean config

### Traefik not routing to app
**Symptoms:** Traefik is healthy but returns 404 for an app's subdomain
**Causes:**
1. App container not running
2. Missing `traefik.enable=true` label
3. Wrong `Host()` rule in labels
4. Container not on `appserver` Docker network
**Check:** Docker labels and network membership

## Cloudflare Tunnel Issues

### Tunnel disconnected
**Symptoms:** All subdomains unreachable, Cloudflare returns 522 or connection error
**Cause:** cloudflared systemd service crashed or lost connection
**Check:** Via SSM: `systemctl status cloudflared` and `journalctl -u cloudflared --since "10 min ago" --no-pager | tail -30`
**Fix:** Restart cloudflared: `systemctl restart cloudflared` via SSM
**Note:** cloudflared runs as a systemd service (`/usr/local/bin/cloudflared`), NOT as a Docker container. `docker logs cloudflared` will fail with "no such container."

### DNS not resolving
**Symptoms:** Subdomain returns DNS error (NXDOMAIN)
**Cause:** DNS CNAME record missing in Cloudflare for that subdomain
**Check:** Is the subdomain in `app_subdomains` in `terraform.tfvars`?
**Fix:** Add subdomain to tfvars, run `./scripts/appserver.sh deploy`

## Infrastructure Issues

### Instance won't start
**Symptoms:** `aws ec2 start-instances` returns error
**Causes:**
1. Insufficient capacity in the AZ (rare for t4g.small)
2. EBS volume issue
3. Account-level EC2 limit reached
**Check:** EC2 console events tab

### SSM not reachable
**Symptoms:** SSM commands time out, instance shows "Connection Lost"
**Causes:**
1. Instance just started (SSM agent takes 1-2 minutes after boot)
2. Instance has no outbound internet (public IP removed, or route table broken)
3. SSM agent crashed
**Check:** Wait 2-3 minutes after start. If still unreachable, check VPC route table

### Deploy fails with IAM error
**Symptoms:** `terraform apply` fails with UnauthorizedOperation
**Cause:** Deployer IAM policy missing a required permission
**Check:** The error message tells you which action and resource failed. Common missing permissions:
- `ec2:RunInstances` on `network-interface/*` or `volume/*` — the deployer policy must allow RunInstances on these as passthrough resources (no tag condition) because AWS doesn't apply request tags to sub-resources created during launch
- `ec2:DescribeInstanceCreditSpecifications` — needed by the AWS provider to read back burstable instance config
**Fix:** Update the relevant policy in `terraform/deployer-policies/`, run `./scripts/appserver.sh init` to push the updated policy, then redeploy

### Config push fails
**Symptoms:** `appserver.sh config push` errors
**Causes:**
1. Instance not running
2. SSM not reachable
3. S3 upload failed (IAM or bucket issue)
4. Traefik restart failed after config extraction
**Check:** The SSM command output. Look for which step failed

### Init fails with "Cannot create AppserverAdmin policy"
**Symptoms:** `appserver.sh init` fails creating the AppserverAdmin policy
**Cause:** The calling user (rockport-admin) doesn't have `iam:CreatePolicy` permission. This happens after a full destroy that deleted the AppserverAdmin policy, or on first-ever setup.
**Fix:** Create the policy manually as root or an IAM admin: IAM → Policies → Create → paste `terraform/appserver-admin-policy.json` → name it `AppserverAdmin` → attach to rockport-admin. This is a one-time bootstrap step. The destroy command now keeps AppserverAdmin intact to avoid this.

### Destroy cleanup fails
**Symptoms:** Bootstrap cleanup during destroy can't delete resources
**Causes:**
1. Script running as deployer profile (can't delete itself) — fixed: destroy now unsets AWS_PROFILE for cleanup
2. State bucket deletion fails after admin policy is deleted — fixed: destroy now deletes state bucket before admin policy
3. AWS profile left in `~/.aws/credentials` with dead keys — fixed: destroy now removes the profile
**Key lesson:** Cleanup order matters: delete deployer user → delete state bucket → delete deployer policies (last, since they grant permissions for the earlier steps). AppserverAdmin is intentionally kept.

### Terraform state lock
**Symptoms:** `terraform apply` says state is locked
**Cause:** Previous terraform operation crashed or is still running
**Fix:** Check if another operation is genuinely running. If not, `terraform force-unlock <LOCK_ID>`

## App Management Issues

### app init fails
**Symptoms:** `appserver.sh app init <name>` errors
**Causes:**
1. Instance not running or SSM not reachable
2. Missing .env.example in `config/apps/<name>/`
**Check:** Is the app configured in `config/apps/<name>/docker-compose.yml`?

### app deploy fails
**Symptoms:** `appserver.sh app deploy <name>` errors
**Causes:**
1. Instance not running or SSM not reachable
2. Docker image not available for ARM64
3. Missing .env on instance (run `app init` first)
4. Artifacts not uploaded (run `deploy` first to create artifacts bucket)
**Fix:** Ensure instance is running, artifacts uploaded, and .env exists

### app env duplicates
**Symptoms:** Environment variable set multiple times in .env
**Cause:** Old bug where `app env` appended instead of upserting (now fixed)
**Fix:** Use `app env <name> KEY=VALUE` which now properly replaces existing keys

## Resource Issues

### Disk full
**Symptoms:** Docker operations fail, "no space left on device"
**Cause:** Docker images/layers/volumes consuming disk on the 20GB volume
**Fix:** `docker system prune -a` via SSM to clean unused images and volumes

### High memory usage
**Symptoms:** Slow responses, containers being killed
**Cause:** t4g.small has only 2GB RAM
**Check:** `free -m` and `docker stats --no-stream`
**Fix:** Add `mem_limit` to app docker-compose.yml, remove unused containers

## Cookie App Issues

### Passkey registration fails
**Symptoms:** User cannot register a passkey, browser shows WebAuthn error
**Causes:**
1. `WEBAUTHN_RP_ID` not set or wrong — must be `matthewdeaves.com` (parent domain)
2. User accessing via IP or wrong domain — WebAuthn requires HTTPS + correct origin
3. Browser doesn't support WebAuthn (very old browsers)
**Check:** `cookie_admin status --json` via SSM — check `webauthn.rp_id`

### Cookie version upgrade issues
**Symptoms:** App crashes or behaves unexpectedly after `app deploy cookie`
**Causes:**
1. New version requires a migration that hasn't run yet — check `showmigrations`
2. New env vars required but not set — check release notes, then `app env cookie`
3. Image not yet published for ARM64 — wait for CD workflow to complete
**Check:** `docker compose logs web --tail 50` for startup errors. Run `cookie_admin status --json` to verify DB and migration state.
**Fix:** If migrations are pending, they run automatically on container start. If env vars are missing, use `app env cookie KEY=VALUE`.

### Device code pairing not working
**Symptoms:** 6-char device codes not accepted, or device code screen not loading
**Causes:**
1. Expired codes (5-minute TTL) — codes expire quickly
2. Stale codes accumulating — run `cleanup_device_codes` to clean up
**Check:** `cookie_admin status --json` — check `device_codes.pending` and `device_codes.stale_expired`
**Fix:** `cleanup_device_codes` via SSM to purge expired codes

### Slow AI features
**Symptoms:** Recipe discover, scale, or other AI features take too long
**Cause:** OpenRouter LLM calls are slow (network + inference time)
**Check:** `cookie_admin status --json` — verify `openrouter.configured` is true and check the model
**Note:** Discover endpoint makes parallel LLM calls (since v1.11.0). If still slow, the bottleneck is upstream (OpenRouter/model provider).

### Stale search images consuming disk
**Symptoms:** Disk usage growing from cached recipe search images
**Check:** `cleanup_search_images --dry-run` via SSM to see what would be cleaned
**Fix:** `cleanup_search_images --days 7` via SSM to delete images not accessed in 7 days

## Security Incidents

### Unexpected user registrations
**Symptoms:** Unknown users appearing in `cookie_admin list-users`
**Check:** `cookie_admin audit --json --lines 100` — look for registration events from unknown sources
**Response:**
1. Deactivate suspicious accounts: `cookie_admin deactivate USERNAME`
2. Review if Cloudflare Access is properly enforcing auth (should return 302 for unauthenticated)
3. Check if the registration endpoint is properly protected

### Inbound security group rule added
**Symptoms:** Security group has inbound rules (should have zero)
**Check:** `aws ec2 describe-security-group-rules` — any non-egress rule is unexpected
**Response:** If the rule is in terraform, remove it and run `./scripts/appserver.sh deploy`. If added manually outside terraform, remove via AWS CLI (`aws ec2 revoke-security-group-ingress`) and investigate who/what added it (CloudTrail). All ingress should be via Cloudflare Tunnel only.
