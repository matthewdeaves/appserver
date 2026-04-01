# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Appserver

Docker app hosting on EC2 behind Cloudflare Tunnel. Each app runs as a Docker Compose stack, routed by Traefik via subdomains (e.g. cookie.matthewdeaves.com).

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, access, monitoring, snapshots)
terraform/main.tf       # EC2 instance (t4g.small ARM), security group, IAM role/policies
terraform/variables.tf  # Input variables (region, domain, subdomains, email, budget)
terraform/outputs.tf    # Terraform outputs (instance ID, app URLs, SSM command)
terraform/providers.tf  # AWS + Cloudflare provider configuration
terraform/versions.tf   # Required provider versions and S3 backend config
terraform/tunnel.tf     # Cloudflare Tunnel + per-app subdomain DNS CNAMEs
terraform/access.tf     # Cloudflare Access (email OTP for browser, service token for CLI)
terraform/monitoring.tf # Monthly budget alarm, EC2 auto-recovery
terraform/snapshots.tf  # Daily EBS snapshots (DLM policy, 7-day retention)
terraform/s3.tf         # Artifacts S3 bucket (deploy config, cloudflared fallback)
terraform/security.tf   # Cloudflare WAF rate limiting + zone security settings
terraform/deployer-policies/ # 3 least-privilege IAM policies (compute, iam-ssm, monitoring-storage)
terraform/appserver-admin-policy.json # Bootstrap IAM policy for admin user
terraform/terraform.tfvars.example    # Example tfvars
terraform/.env.example               # Example .env (Cloudflare API token)
config/traefik/         # Traefik reverse proxy config + compose
config/apps/            # Per-app Docker Compose files + env examples
pentest/                # Penetration testing toolkit (invoke via /pentest skill)
pentest/pentest.sh      # Pentest CLI (run, list, modules, report)
pentest/install.sh      # Tool installer (nmap, ffuf, nuclei, testssl, wordlists)
pentest/scripts/        # Test modules (api, auth, headers, infra, ssrf, webauthn, etc.)
pentest/targets/        # Target configs with endpoint inventory + known vulns
pentest/tools/          # Wordlists (testssl cloned at runtime via install.sh)
pentest/reports/        # Scan results (gitignored)
scripts/appserver.sh    # Admin CLI (init, deploy, status, app management)
scripts/bootstrap.sh    # EC2 user_data (Docker, Traefik, cloudflared)
.github/workflows/      # CI — terraform fmt, validate, shellcheck, gitleaks
.github/dependabot.yml  # Dependabot version updates (Terraform, Actions, Docker)
SECURITY.md             # Vulnerability reporting policy
README.md               # Project overview
```

## Key Commands

```bash
./scripts/appserver.sh init          # Interactive setup (IAM, state bucket, tfvars)
./scripts/appserver.sh deploy        # terraform init + apply
./scripts/appserver.sh destroy       # terraform destroy + optional bootstrap cleanup
./scripts/appserver.sh status        # Running containers + resource usage
./scripts/appserver.sh start         # Start EC2 instance
./scripts/appserver.sh stop          # Stop EC2 instance
./scripts/appserver.sh ssh           # SSM session to instance
./scripts/appserver.sh logs [app]    # Container logs
./scripts/appserver.sh spend         # AWS cost breakdown
./scripts/appserver.sh app init <name>     # Generate secrets + create .env on instance
./scripts/appserver.sh app deploy <name>   # Pull image + restart app
./scripts/appserver.sh app list            # Show all apps + status
./scripts/appserver.sh app remove <name>   # Stop + remove app
./scripts/appserver.sh app restart <name>  # Restart app containers
./scripts/appserver.sh app env <name>      # View/set env vars
./scripts/appserver.sh config push         # Push config + restart Traefik
```

## Deploying Cookie (First Time)

```bash
./scripts/appserver.sh deploy              # Provision EC2 + Cloudflare
./scripts/appserver.sh app init cookie     # Auto-generate all secrets
./scripts/appserver.sh app deploy cookie   # Pull image + start
# Visit https://cookie.matthewdeaves.com
# Register your first passkey — first user becomes admin
```

`app init` auto-generates cryptographically random values for:
- `POSTGRES_PASSWORD` (32 chars)
- `SECRET_KEY` (50 chars, Django signing key)

And sets passkey mode defaults:
- `AUTH_MODE=passkey`
- `WEBAUTHN_RP_ID=matthewdeaves.com` (parent domain — passkeys work across all subdomains)

## Adding a New App

1. Add subdomain to `app_subdomains` in `terraform/terraform.tfvars`
2. Create `config/apps/<name>/docker-compose.yml` with Traefik labels
3. Create `config/apps/<name>/.env.example` with placeholder secrets
4. Run `./scripts/appserver.sh deploy` (creates DNS + Access policy)
5. Run `./scripts/appserver.sh app init <name>` to generate secrets
6. Run `./scripts/appserver.sh app deploy <name>` to start

### Required Traefik Labels

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<name>.rule=Host(`<name>.matthewdeaves.com`)"
  - "traefik.http.routers.<name>.entrypoints=web"
  - "traefik.http.services.<name>.loadbalancer.server.port=<port>"
networks:
  - default
  - appserver
```

## Linting and Validation

CI runs on push/PR to main (`.github/workflows/validate.yml`). Run locally before committing:

```bash
terraform -chdir=terraform fmt -check -recursive   # Terraform formatting
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate  # Terraform validation
shellcheck scripts/*.sh                             # Shell script linting
```

## Architecture

- **EC2**: t4g.small (ARM/Graviton), Amazon Linux 2023, 20GB gp3 encrypted EBS
- **Ingress**: Cloudflare Tunnel (zero inbound security group rules)
- **Auth**: Cloudflare Access — email OTP for browser, service token for CLI
- **Routing**: Traefik reverse proxy — routes subdomains via Docker labels
- **Remote access**: AWS SSM (no SSH keys, no open ports)
- **Monitoring**: Monthly budget alarm ($10), EC2 auto-recovery, daily EBS snapshots (7-day retention)

## Important Notes

- `user_data` (bootstrap.sh) only runs on first boot; use `config push` for runtime updates
- Traffic flow: Client -> Cloudflare -> Tunnel -> Traefik (:80) -> App container
- No inbound ports open — EC2 only reachable via Cloudflare Tunnel and SSM
- ARM architecture (aarch64) — Docker images must support linux/arm64
- Same AWS account as Rockport — resources isolated by naming/tagging (appserver-*)
- App secrets (.env files) are NOT uploaded via artifacts — use `app init` to generate or `app env` to set
- Region is read from `terraform.tfvars` by appserver.sh — no hardcoded region
- Cloudflare API token needs: Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Account Cloudflare Tunnel Edit, Account Zero Trust Edit
- The CLI requires `aws`, `terraform`, and `jq`
- `deploy` auto-uploads artifacts before running terraform
- `app deploy` pulls artifacts + latest Docker image, then restarts the compose stack
- `app remove` preserves Docker volumes — delete manually if needed
- Cookie image version is pinned in `docker-compose.yml` (single source of truth). To upgrade: update the version in compose, commit, `config push`, `app deploy`. Do NOT set `COOKIE_VERSION` in the instance `.env` — the compose default is authoritative
- Cookie publishes multi-arch images (amd64 + arm64) via CD workflow on semantic version tags
- Traefik is pinned to v3.4.0 with health check via `traefik healthcheck --ping`
- Traefik forwards Cloudflare headers (CF-Connecting-IP, X-Forwarded-For) via `forwardedHeaders.trustedIPs` (Cloudflare IP ranges only)
- App names must be lowercase alphanumeric with hyphens — validated by the CLI
- SSM commands use `jq` for safe JSON encoding (no string interpolation injection)
- `app env` masks values when displaying (shows KEY=***) and validates KEY=VALUE format
- Bootstrap retries tunnel token fetch 5 times with 10s backoff
- Cookie runs in passkey (WebAuthn) auth mode — no passwords, biometric/PIN only
- `WEBAUTHN_RP_ID` is set to `matthewdeaves.com` (parent domain) so passkeys work across all subdomains
- First user to register at `/register` is automatically promoted to admin
- `app init` generates POSTGRES_PASSWORD and SECRET_KEY with `openssl rand` — never uses defaults
- Django SECRET_KEY must persist across container restarts (stored in .env on instance)
- Device code flow allows legacy devices without WebAuthn support to pair via 6-char codes
- Cookie v1.13.0+ has built-in cron jobs: `cleanup_device_codes` (hourly), `cleanup_sessions` (daily 3:15 AM), `cleanup_search_images` (daily 3:30 AM)
- `python manage.py cookie_admin status --json` includes `maintenance` block with last-run timestamps for each cron job and `device_codes` counts (pending/stale)
- As of v1.22.0, `cookie_admin` is a Django management command — run via `python manage.py cookie_admin`, not as a standalone binary
- Cron output is redirected to container stdout (`/proc/1/fd/1`) so it appears in `docker logs`

## Penetration Testing

The `pentest/` directory contains a bash-based security testing toolkit. Invoke via the `/pentest` skill.

```bash
./pentest/pentest.sh run cookie              # Full app-layer scan
./pentest/pentest.sh run appserver           # Full infra-layer scan
./pentest/pentest.sh run cookie --module ssrf # Single module
./pentest/pentest.sh modules                 # List all modules
./pentest/pentest.sh report cookie           # Show latest report
```

### Important Notes

- Tests hit the live production site through Cloudflare — allowlist your IP in CF WAF before scanning
- Run `pentest/install.sh` once to install tools (nmap, ffuf, nuclei, testssl.sh, wordlists)
- Target configs (`pentest/targets/*.yaml`) document all known endpoints, rate limits, and vulnerabilities
- Reports are gitignored — findings stay local
- 13 modules: recon, headers, tls, paths, nikto, nuclei, api, auth, injection, ssrf, infra, legacy, webauthn
- Default rate: 5 req/s. Use `--rate 2` for auth endpoints to avoid Cloudflare WAF blocks
- The `appserver` target auto-skips app-layer modules; use the `cookie` target for app testing
