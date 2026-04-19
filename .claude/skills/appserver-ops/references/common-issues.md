# Common Issues

Known symptom-to-cause mappings for appserver infrastructure. For Cookie-specific issues (passkeys, device codes, cron jobs, AI features), see `/cookie-ops`.

## Connection Failures

### HTTP 403 "Sorry, you have been blocked" (Cloudflare WAF)
**Symptoms:** All requests to any appserver subdomain return "Sorry, you have been blocked"
**Cause:** A zone-wide Cloudflare WAF rule from another project (e.g. Rockport's path allowlist) is blocking requests. WAF custom rules apply to the entire zone unless host-scoped.
**Check:** Security > Events in the Cloudflare dashboard. Look for the Ray ID in the error page.
**Fix:** Scope the blocking WAF rule to its own subdomain only, e.g. add `(http.host eq "llm.matthewdeaves.com")` to the rule expression.
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
6. Entrypoint DB wait loop failing for non-DB reasons (error swallowed by `2>/dev/null`)
**Check:** `docker compose logs APP` for the startup error. If logs show DB wait loop but DB is healthy, the issue may be in the entrypoint.
**SSL note:** Containers behind Cloudflare Tunnel + Traefik should NOT use SSL internally.

### App works but shows wrong behavior
**Symptoms:** App is running and reachable but features don't work as expected
**Cause:** Internal nginx overwriting `X-Forwarded-Proto` header with `$scheme` (http behind Traefik). Django's `SECURE_SSL_REDIRECT` then 301-redirects API calls.
**Check:** `docker exec APP curl -sv http://localhost/api/endpoint/ 2>&1 | grep Location`
**Fix:** App's nginx must pass through `X-Forwarded-Proto`, or set `SECURE_SSL_REDIRECT=false`.
**Key lesson:** Traffic flow is Client > Cloudflare (HTTPS) > Tunnel > Traefik (HTTP, sets X-Forwarded-Proto: https) > nginx (HTTP) > app. Every layer must preserve the proto header.

### App container OOM killed
**Symptoms:** Container suddenly stops, `docker inspect` shows OOMKilled: true
**Cause:** t4g.small has 2GB RAM total shared across all containers
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
**Check:** Compare docker-compose.yml labels against requirements in CLAUDE.md

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
**Fix:** Restart: `systemctl restart cloudflared` via SSM
**Note:** cloudflared is systemd, NOT Docker. `docker logs cloudflared` will fail.

### DNS not resolving
**Symptoms:** Subdomain returns DNS error (NXDOMAIN)
**Cause:** DNS CNAME record missing in Cloudflare
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
2. Instance has no outbound internet
3. SSM agent crashed
**Check:** Wait 2-3 minutes after start. If still unreachable, check VPC route table

### Deploy fails with IAM error
**Symptoms:** `terraform apply` fails with UnauthorizedOperation
**Cause:** Deployer IAM policy missing a required permission
**Check:** The error message tells you which action and resource failed.
**Fix:** Update the relevant policy in `terraform/deployer-policies/`, run `init` then redeploy

### Config push fails
**Symptoms:** `appserver.sh config push` errors
**Causes:**
1. Instance not running
2. SSM not reachable
3. S3 upload failed
4. Traefik restart failed after config extraction
**Check:** SSM command output. Look for which step failed

### Init fails with "Cannot create AppserverAdmin policy"
**Symptoms:** `appserver.sh init` fails creating the AppserverAdmin policy
**Cause:** Calling user doesn't have `iam:CreatePolicy` permission (deployer profile is active, or default creds lack admin)
**Fix:** `init` needs admin credentials — unset `AWS_PROFILE` (or switch to an admin profile) before running. Create the policy manually as root/IAM admin if the admin user itself lacks `iam:CreatePolicy`. One-time bootstrap step — `destroy` keeps AppserverAdmin intact for re-init.
**Note:** most "new machine" setups don't need `init` at all. If deployer IAM + state bucket already exist, use `./scripts/appserver.sh setup local` (writes local config without touching AWS) and go straight to `deploy`.

### Terraform state lock
**Symptoms:** `terraform apply` says state is locked
**Cause:** Previous terraform operation crashed or still running
**Fix:** Check if another operation is running. If not, `terraform force-unlock <LOCK_ID>`

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
4. Artifacts not uploaded (run `deploy` first)
**Fix:** Ensure instance is running, artifacts uploaded, .env exists

### app env duplicates
**Symptoms:** Environment variable set multiple times in .env
**Cause:** Old bug where `app env` appended instead of upserting (now fixed)
**Fix:** Use `app env <name> KEY=VALUE` which properly replaces existing keys

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

## Security Incidents

### Unexpected user registrations
**Symptoms:** Unknown users appearing in app user lists
**Check:** App-specific audit commands (e.g. `cookie_admin audit` for Cookie)
**Response:** Deactivate suspicious accounts, verify Cloudflare Access is enforcing auth

### Inbound security group rule added
**Symptoms:** Security group has inbound rules (should have zero)
**Check:** `aws ec2 describe-security-group-rules` — any non-egress rule is unexpected
**Response:** Remove via terraform and investigate who/what added it (CloudTrail). All ingress should be via Cloudflare Tunnel only.
