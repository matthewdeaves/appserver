# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Appserver

Docker app hosting on EC2 behind Cloudflare Tunnel. Each app runs as a Docker Compose stack, routed by Traefik via subdomains (e.g. cookie.matthewdeaves.com).

## Project Structure

```
terraform/              # All infrastructure (EC2, IAM, SG, tunnel, access, monitoring, snapshots)
config/traefik/         # Traefik reverse proxy config + compose
config/apps/            # Per-app Docker Compose files + env examples
pentest/                # Penetration testing toolkit (invoke via /pentest skill)
pentest/orchestrator/   # Python orchestrator — CLI, config, auth, module runner, results
pentest/scripts/        # Bash module scripts (14 modules) + common.sh shared helpers
pentest/hexstrike/      # HexStrike AI — agent-driven exploratory security testing (Docker)
scripts/appserver.sh    # Admin CLI (init, deploy, status, app management)
scripts/bootstrap.sh    # EC2 user_data (Docker, Traefik, cloudflared)
.github/workflows/      # CI — terraform fmt, validate, shellcheck, gitleaks
```

## Key Commands

```bash
./scripts/appserver.sh init          # First-time AWS infra bootstrap (IAM + state bucket, needs admin creds)
./scripts/appserver.sh setup local   # Write terraform/.env + tfvars on a new dev machine (no AWS admin)
./scripts/appserver.sh deploy        # terraform init + apply
./scripts/appserver.sh destroy       # terraform destroy + optional bootstrap cleanup
./scripts/appserver.sh status        # Running containers + resource usage
./scripts/appserver.sh start         # Start EC2 instance
./scripts/appserver.sh stop          # Stop EC2 instance
./scripts/appserver.sh ssh           # SSM session to instance
./scripts/appserver.sh logs [app|bootstrap]  # Container logs, or bootstrap for /var/log/appserver-bootstrap.log
./scripts/appserver.sh spend         # AWS cost breakdown
./scripts/appserver.sh app init <name>     # Generate secrets + create .env on instance
./scripts/appserver.sh app deploy <name>   # Pull image + restart app
./scripts/appserver.sh app list            # Show all apps + status
./scripts/appserver.sh app remove <name>   # Stop + remove app
./scripts/appserver.sh app restart <name>  # Restart app containers
./scripts/appserver.sh app env <name>      # View/set env vars
./scripts/appserver.sh config push              # Push config + restart Traefik
./scripts/appserver.sh config check-ips        # Audit Cloudflare IP ranges in traefik.yml
./scripts/appserver.sh config check-ips --fix  # Auto-sync stale ranges
./scripts/appserver.sh threats                 # Analyze access logs for threats (last 24h)
./scripts/appserver.sh threats --since 1h      # Analyze last hour
./scripts/appserver.sh threats report          # View latest threat report
./scripts/appserver.sh threats list            # List all threat reports
./scripts/appserver.sh threats block <ip>      # Block IP via Cloudflare WAF
./scripts/appserver.sh threats unblock <ip>    # Unblock IP
./scripts/appserver.sh threats blocked         # List blocked IPs
./scripts/appserver.sh threats allow [<ip>]    # Allowlist IP in CF WAF (defaults to public IP; use for pentests)
./scripts/appserver.sh threats unallow <ip>    # Remove allowlist rule
./scripts/appserver.sh threats allowed         # List allowlisted IPs
./scripts/appserver.sh setup unlock            # Decrypt pentest targets (key from SSM)
./scripts/appserver.sh setup lock              # Re-encrypt pentest targets
```

## Developer Setup

Three scenarios — pick one based on AWS account state (see README for the full decision table):

- **A. Brand-new AWS account**: `init` (needs admin creds) → `deploy` → `app init cookie` → `app deploy cookie`
- **B. Joining live infra on a new dev machine**: `aws configure --profile appserver` + `setup local` → `status`
- **C. Rebuilding after a destroy** (IAM + state bucket still exist, no live infra): `aws configure --profile appserver` + `setup local` → `deploy` → `app init cookie` → `app deploy cookie`

Secrets needed for B/C (from the password vault or Cloudflare/AWS console):
- AWS deployer access key/secret for the `appserver-deployer` IAM user
- Cloudflare API token (Zone DNS/Settings/WAF/DNSSEC Edit, Account Tunnel Edit, Account Zero Trust Edit)
- Cloudflare zone ID + account ID for the domain (not secrets, but `setup local` prompts for them)
- GitHub SSH key

Run `setup local` (interactive) to write `terraform/.env` + `terraform/terraform.tfvars`. It makes no AWS calls, so it's safe with the deployer profile or before any AWS credentials exist.

`init` is idempotent but requires admin AWS credentials (can't run as the deployer user). Use it only for scenario A, or if a prior `destroy --cleanup-bootstrap` wiped the IAM user + state bucket.

Optional: decrypt pentest target configs (requires SSM access + `git-crypt` installed locally):
```bash
./scripts/appserver.sh setup unlock            # Fetches key from SSM automatically
./scripts/appserver.sh setup unlock /path/to/appserver.key  # Or use a local key file
```

Pentest target YAMLs (`pentest/targets/*.yaml`) are encrypted via git-crypt. They contain attack surface details, rate limits, and vulnerability history. The `.example` files are plain-text templates.

Multi-machine gotchas: no Terraform state locking (S3 backend has no DynamoDB lock table — don't run `deploy` from two machines at once), deployer key has full infra + Cookie admin blast radius, prefer one Cloudflare token per machine for individual revocability.

## Deploying Cookie

After `deploy` has provisioned the instance (scenario A or C), bring Cookie up:

```bash
./scripts/appserver.sh app init cookie     # Auto-generate all secrets
./scripts/appserver.sh app deploy cookie   # Pull image + start
# Visit https://cookie.matthewdeaves.com
# Register your first passkey. v1.43.0+: there is no admin tier — all users are peers.
# Mode-gated ops (reset, API key, prompts, sources, quotas) run via cookie_admin CLI:
# docker exec cookie-web python manage.py cookie_admin list-users --json
# docker exec cookie-web python manage.py cookie_admin reset --confirm --json     # factory reset
# docker exec cookie-web python manage.py cookie_admin set-unlimited <user> --json # AI-quota exemption
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
- Cloudflare API token needs: Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Zone DNSSEC Edit, Account Cloudflare Tunnel Edit, Account Zero Trust Edit
- The CLI requires `aws`, `terraform`, and `jq`
- `deploy` runs terraform apply, then uploads artifacts to S3
- `app deploy` pulls artifacts + latest Docker image, then restarts the compose stack
- `app remove` preserves Docker volumes — delete manually if needed
- Cookie image version is pinned in `docker-compose.yml` (single source of truth). To upgrade: update the version in compose, commit, `config push`, `app deploy`. Do NOT set `COOKIE_VERSION` in the instance `.env` — the compose default is authoritative
- Cookie publishes multi-arch images (amd64 + arm64) via CD workflow on semantic version tags
- Traefik is pinned to v3.4.0 with health check via `traefik healthcheck --ping`
- Traefik forwards Cloudflare headers (CF-Connecting-IP, X-Forwarded-For) via `forwardedHeaders.trustedIPs` (Cloudflare IP ranges only)
- Cloudflare IP ranges in traefik.yml can drift — run `config check-ips` periodically to audit, `--fix` to auto-sync
- App names must be lowercase alphanumeric with hyphens — validated by the CLI
- SSM commands use `jq` for safe JSON encoding (no string interpolation injection)
- `app env` masks values when displaying (shows KEY=***) and validates KEY=VALUE format
- Bootstrap retries tunnel token fetch 5 times with 10s backoff
- Django `createsuperuser` is blocked. v1.43.0: no admin tier — use `cookie_admin set-unlimited` for per-user AI-quota exemption, or run admin-style ops via CLI subcommands directly
- Device code flow allows legacy devices without WebAuthn support to pair via 6-char codes
- Cookie v1.13.0+ has built-in cron jobs: `cleanup_device_codes` (hourly), `cleanup_sessions` (daily 3:15 AM), `cleanup_search_images` (daily 3:30 AM)
- `python manage.py cookie_admin status --json` includes `maintenance` block keyed by `device_code_cleanup` / `session_cleanup` / `search_image_cleanup` — each value is either the string `"never run"` or an object with `time` and job-specific counters; also `device_codes` counts (pending/stale)
- Running cookie version is NOT in `status --json` (removed v1.42.0 as fingerprint fix) — get it via `docker ps --filter name=cookie-web --format '{{.Image}}'`
- Cookie v1.42.0+ gates admin UI by auth mode: passkey mode hides API-key/model/prompts/sources/quota/danger-zone sections in both legacy and SPA frontends; those settings are CLI-only via `cookie_admin`. Subcommands: `set-api-key`, `test-api-key`, `set-default-model`, `prompts {list,show,set}`, `sources {list,toggle,toggle-all,set-selector,test,repair}`, `quota {show,set}`, `rename`. Home mode keeps the full web admin UI
- Cookie v1.43.0 retired `is_staff` and removed the `AdminAuth` class. `HomeOnlyAdminAuth` renamed to `HomeOnlyAuth` (mode gate only, no privilege check). cookie_admin `promote`/`demote` subcommands removed; `--admin` flag removed from `create-user`; `--admins-only` flag removed from `list-users`; `is_admin` field stripped from `status`, `list-users`, `audit` JSON and from `/auth/me` response. Per-user privilege is now only `Profile.unlimited_ai` (set via `cookie_admin set-unlimited`/`remove-unlimited`)
- Cron output is redirected to container stdout (`/proc/1/fd/1`) so it appears in `docker logs`

## Penetration Testing

Two complementary approaches: a **curated pentest suite** for deterministic regression testing and **HexStrike AI** for agent-driven exploratory testing.

### Curated Suite

The `pentest/` directory contains a Python-orchestrated security testing toolkit with bash module scripts. Invoke via the `/pentest` skill.

```bash
./pentest/pentest.sh run cookie              # Full app-layer scan
./pentest/pentest.sh run appserver           # Full infra-layer scan
./pentest/pentest.sh run-all                 # Both targets in sequence
./pentest/pentest.sh run cookie --module ssrf # Single module
./pentest/pentest.sh run cookie --verbose    # Show full module output on terminal
./pentest/pentest.sh modules                 # List all modules
./pentest/pentest.sh report cookie           # Show latest report
```

**Architecture**: `pentest.sh` is a thin bash wrapper (~90 lines) that handles sudo, CF Access curl injection, and terraform init, then delegates to a Python orchestrator (`pentest/orchestrator/`). The orchestrator handles CLI parsing, target YAML loading, SSM auth bootstrap, module execution, tag counting, results.json assembly, and report generation. Module scripts (14 bash files in `pentest/scripts/`) are the actual test logic — they source `common.sh` for shared helpers (`setup_csrf`, `setup_sleep`, `url_encode`, `json_get`).

#### Important Notes

- Tests hit the live production site through Cloudflare — allowlist your IP in CF WAF before scanning
- Run `pentest/install.sh` once to install tools (nmap, ffuf, nuclei, testssl.sh, wordlists)
- Target configs (`pentest/targets/*.yaml`) document all known endpoints, rate limits, and vulnerabilities
- Reports are gitignored — findings stay local
- 14 modules: recon, headers, tls, nikto, nuclei, api, auth, ai, injection, ssrf, infra, legacy, webauthn, paths
- Default rate: 50 req/s. Auth endpoints (`/api/auth/`) automatically use 2 req/s to stay under Cloudflare WAF rate limits (20 req/10s)
- The `appserver` target auto-skips app-layer modules; use the `cookie` target for app testing
- Report directory structure: `reports/<target>/<timestamp>/` with `results.json` (machine-readable), `SUMMARY.md` (human-readable), `run.log` (full transcript), `modules/` (per-module output), `tools/` (tool artifacts)
- Use `/pentest-review` skill to review scan results; it prefers `results.json` for quick structured triage
- Module scripts source `pentest/scripts/common.sh` for shared CSRF setup, sleep derivation, and payload loading
- The orchestrator exports `HOSTNAME`, `API_BASE`, `TARGET_URL`, auth session IDs, and other env vars to module subprocesses

### HexStrike AI (Exploratory)

`pentest/hexstrike/` contains a Dockerized HexStrike AI instance for agent-driven exploratory testing. It runs in its own container (Kali base + web-pentest tools) and is accessed via MCP — no coupling to the curated suite.

```bash
cd pentest/hexstrike && docker compose up -d   # Start HexStrike container
# Configure MCP in Claude Code using mcp-config.example.json
# Scope briefs in briefs/cookie.md and briefs/appserver.md
```

- Localhost-only (:8888), NET_RAW/NET_ADMIN caps for network tools
- Does not invoke pentest.sh, the orchestrator, or module scripts
- Briefs are plain-text scope summaries (not derived from encrypted target YAMLs)

## Security Reviews

Independent security reviews are tracked in GitHub issues #3 (infra) and #6 (app). Key design decisions:

- **Permissions boundary** on instance role caps effective permissions regardless of inline/managed policies
- **Deployer IAM** restricted: deny on inline policies for instance role, managed policy allowlist enforced
- **State bucket** principal-restricted policy limits access to deployer + root only
- **Traefik HSTS** middleware adds defense-in-depth (Cookie nginx + Cloudflare also set HSTS)
- **tfsec** runs in CI to catch IaC security misconfigurations
- **LOW-1 (`home_ip`)** and **LOW-2 (Docker socket)** are accepted risks — see SECURITY.md
- Pentest targets (`pentest/targets/*.yaml`) document all findings with fix history

## Threat Analysis

The `threats` subcommand provides access log analysis and Cloudflare WAF integration for detecting and blocking attackers. Invoke via the `/threat-ops` skill or CLI directly.

- Traefik access logs (JSON format) are written to `/var/log/traefik/access.log` on the instance
- Log rotation: daily, 14-day retention, compressed, ~500MB budget (`/etc/logrotate.d/traefik`)
- Analysis runs on-instance via SSM (jq processes access logs, returns JSON summary)
- Reports are stored locally in `reports/threats/<timestamp>/` (gitignored)
- Report files: `report.json` (machine), `SUMMARY.md` (human), `actions.json` (audit trail)
- IP blocking uses Cloudflare IP Access Rules API (not Terraform — ephemeral operational actions)
- CF edge data (WAF blocks, rate limits) is optionally enriched via GraphQL Analytics API
- `CLOUDFLARE_API_TOKEN` must be set for block/unblock/blocked commands (Zone WAF Edit permission)
- The threat-ops skill (`/threat-ops`) orchestrates analysis and offers to enact high-confidence block recommendations
