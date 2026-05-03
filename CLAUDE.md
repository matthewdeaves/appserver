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
pentest/hooks/          # Consumer hooks (preflight, auth-bootstrap, health-check, scan-summary)
pentest/scripts/        # Cookie-only modules (ai, webauthn) — generic modules live in pentest-kit
pentest/targets/        # Target YAMLs (cookie.yaml, appserver.yaml)
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

### MFA-gated operator roles (003-iam-mfa-scoping)

Routine CLI commands run via three MFA-gated IAM roles assumed from the deployer user:

- `appserver-readonly-role` — pure AWS reads only (`spend`, `threats analyze/list/report/blocked/allowed`, `setup unlock`). No `ssm:SendCommand`.
- `appserver-cookie-ops-role` — anything that runs shell on the instance via SSM, plus app management (`status`, `health`, `users`, `logs`, `app list/deploy/init/remove/restart/env`, `config push`, `threats block/unblock/allow/unallow`)
- `appserver-deploy-role` — full infra changes (`deploy`, `destroy`, `start`, `stop`, `ssh`)

Sessions are 1 hour; the CLI auto-assumes the right role per subcommand. One-time setup per machine:

1. Enrol a TOTP MFA device on `appserver-deployer` via the AWS console (manual operator step)
2. Add `MFA_SERIAL_NUMBER=arn:aws:iam::<account-id>:mfa/appserver-deployer` to the local terraform env file
3. Run `./scripts/appserver.sh auth` to assume a role; subsequent CLI calls reuse cached sessions

After the phase-5 cutover, the deployer user only holds `AppserverDeployerAssumeRoles`; the access key on disk can only call MFA-gated `sts:AssumeRole` and is useless without the TOTP code. See `specs/003-iam-mfa-scoping/HANDOFF.md` for the apply sequence and recovery options.

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
- **Auth**: Cloudflare Access — service token for CLI only. Cookie subdomain is public (`public_app_subdomains = ["cookie"]` in terraform.tfvars); passkey auth is the only gate. Other subdomains remain email OTP protected.
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
- Traefik is pinned to v3.6.15 with health check via `traefik healthcheck --ping`
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

### Sibling pentest-kit dependency

The harness scripts (`pentest/harness.sh` and `pentest/hexstrike/harness.sh`) are thin wrappers that delegate to [pentest-kit](https://github.com/matthewdeaves/pentest-kit) — a public library with the iteration loop, state management, and HexStrike Docker image. Clone it as a sibling:

```bash
git clone https://github.com/matthewdeaves/pentest-kit ~/pentest-kit
```

The wrappers resolve the kit via `$PENTEST_KIT_DIR` → `../pentest-kit` → `~/pentest-kit`. Override with `PENTEST_KIT_DIR=...` if you keep it elsewhere.

**Don't `git pull` the kit while a scan is in flight** — behavior would shift mid-loop. If you need a stable kit version, pin a SHA in your wrapper (`cd ~/pentest-kit && git checkout <sha>`).

The consumer-side artifacts (target YAMLs, hooks like `pentest/hooks/scan-summary.sh`, the appserver-specific HARNESS_PROMPT.md) live in this repo. Future migration phases will move more of `pentest/` (orchestrator, generic modules, payloads) into the kit.

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

**Architecture**: `pentest.sh` is a ~90-line wrapper that resolves the pentest-kit clone, runs the consumer's `hooks/preflight.sh` (terraform/CF Access setup), then exec's the kit's orchestrator (`python3 -m pentest_kit.orchestrator`). The orchestrator (in `~/pentest-kit/pentest_kit/orchestrator/`) handles CLI parsing, target YAML loading, module discovery across kit + consumer scripts dirs, hook invocation (auth-bootstrap, health-check), module execution, results.json assembly, and report generation. 12 generic modules ship in the kit (`~/pentest-kit/pentest_kit/scripts/`); the 2 Cookie-specific modules (`ai.sh`, `webauthn.sh`) stay in `pentest/scripts/` and are picked up via PENTEST_SCRIPTS_DIRS (consumer-wins on collision). All modules source `common.sh` from the kit.

#### Important Notes

- Tests hit the live production site through Cloudflare — allowlist your IP in CF WAF before scanning
- Run `pentest/install.sh` once to install tools (nmap, ffuf, nuclei, testssl.sh, wordlists)
- Target configs (`pentest/targets/*.yaml`) document all known endpoints, rate limits, and vulnerabilities
- Reports are gitignored — findings stay local
- 14 modules total — 12 generic in `~/pentest-kit/pentest_kit/scripts/` (recon, headers, tls, nikto, nuclei, api, auth, injection, ssrf, infra, legacy, paths); 2 Cookie-specific in `pentest/scripts/` (ai, webauthn). Module discovery merges both via PENTEST_SCRIPTS_DIRS
- Default rate: 50 req/s. Auth endpoints (`/api/auth/`) automatically use 2 req/s to stay under Cloudflare WAF rate limits (20 req/10s)
- The `appserver` target auto-skips app-layer modules; use the `cookie` target for app testing
- Report directory structure: `reports/<target>/<timestamp>/` with `results.json` (machine-readable), `SUMMARY.md` (human-readable), `run.log` (full transcript), `modules/` (per-module output), `tools/` (tool artifacts)
- Use `/pentest-review` skill to review scan results; it prefers `results.json` for quick structured triage
- Module scripts source `common.sh` from the kit (`$PENTEST_KIT_DIR/pentest_kit/scripts/common.sh`) for shared CSRF setup, sleep derivation, payload loading, and the new `load_endpoints` helper
- The orchestrator exports `HOSTNAME`, `API_BASE`, `TARGET_URL`, auth session IDs, and other env vars to module subprocesses
- **Running the harness from Claude Code**: use `Bash(..., run_in_background=True)` and wait for the single `task-notification { status: completed }` event. Do NOT use `Monitor` to watch harness PIDs — it creates a heartbeat feedback loop where each "still alive" notification prompts another Monitor spawn. See pentest-kit CLAUDE.md for details.

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

## Blast-radius gates for Claude Code

This repo is operated by Claude Code. The agent has broad shell access
(SSM into a live EC2 instance, terraform apply, docker, AWS APIs) — the
same blast radius that took down PocketOS in April 2026 when a Cursor +
Claude agent hit a permissions error mid-task and "fixed" it by deleting
the production database in 9 seconds. To prevent that class of failure
here, several layers gate destructive operations:

### Layer 1 — User-side approval (built-in)
Claude Code's permission system asks before each Bash invocation unless
the user has pre-approved the tool / mode. This is the primary gate; the
hooks below exist because pre-approval is sometimes broad and "yes to
all" is a real foot-gun.

### Layer 2 — `block-credential-reads.sh` PreToolUse hook
Two classes blocked: (a) `cat`/`grep`/`head`/`tail`/`sed`/`awk`/`less`/`jq`
against credential paths inside shell commands (`terraform/.env`,
`~/.aws/credentials`, `.git-crypt/`) and any `bash -x` / `set -x` xtrace
flag (which would dump sourced secrets to stdout); (b) CLI commands that
**print** live credentials to stdout — `gh auth token`,
`gh auth status --show-token`, `aws iam create-access-key`,
`aws sts get-session-token`/`get-federation-token`/`assume-role`. The
second class evades file-read patterns because the secret is generated
on the fly, not read from disk.

### Layer 3 — `block-destructive.sh` PreToolUse hook
Denies irreversible verbs Claude is unlikely to need on its own. The
catalogue is a single array (scope/regex/reason) so the SSM payload
scanner can re-use it instead of duplicating a subset.
- **Filesystem**: `rm -rf` of `/`, `~`, `$HOME`, `.`, `..`; `dd of=/dev/sd*`; `mkfs`; `find /` `-delete`; `shred -u`
- **Wide perms**: `chmod 0777`/`a+rwx` on root paths, `chown` of `/`/`~`/`$HOME`
- **Pipe-to-shell**: `curl|bash`, `wget|sh`, `bash <(curl ...)`, `source <(curl ...)`
- **Git**: force push (incl. `--force-with-lease`), `reset --hard`, `filter-repo`/`filter-branch`, `branch -D main`, `clean -f`, `checkout -- .`, `--no-verify`, `--no-gpg-sign`
- **Git remote-tampering**: `remote set-url`/`remove`, `push --delete`, `push origin :branch`, `tag -d`, `push :refs/tags/X`
- **Docker**: `volume rm`/`prune`, `system prune --volumes`, `rm -v`, `compose down -v`
- **DB**: `DROP`/`TRUNCATE`/`dropdb`, `DELETE FROM <table>` without `WHERE`
- **Terraform**: `destroy`, `state rm`, `apply -auto-approve`
- **AWS**: `s3 rb`, `s3 rm --recursive`, IAM/EC2/RDS/Route53/KMS deletions
- **Cloudflare**: `cloudflared tunnel delete`, access-token revoke, direct `curl -X DELETE/PATCH api.cloudflare.com` (legitimate threat-ops calls go through `appserver.sh`, which is not affected)
- **SSM**: `aws ssm send-command` is intercepted before the top-level scan — the `commands=...` payload is extracted (handles `"..."`, `'...'`, and JSON-list `[...]` forms), unquoted, and scanned with the full `all`-scope ruleset so `rm -rf /"` smuggled inside a quoted SSM payload matches the same patterns as a plain `rm -rf /`.
- **Project-specific**: `appserver.sh destroy`, `appserver.sh app remove`
- **System**: `kill -9 1`, `shutdown`/`reboot`/`poweroff`/`halt`, fork bombs

If the user really wants any of these, they run it themselves in their
own shell — the hook only fires for Bash invocations made by Claude.

### Layer 4 — `audit-bash.sh` PostToolUse hook
Every Bash invocation Claude makes is appended to `.claude/audit.log`
(gitignored, JSON Lines: timestamp, cwd, status, command, truncated
stdout/stderr). Rotates at 10 MB to `audit.log.1`; one previous file
is kept. Forensic trail for "what did the agent run between healthy
and broken?" — cheap context to feed back into Claude when investigating.

### Layer 5 — `pentest-bash-gotchas.sh` and `pentest-shellcheck.sh`
Pre/Post Edit/Write hooks that lint pentest module scripts at write
time. Catch classes of shell bug (`((var++))` under `set -e`, `local`
inside loops, `exit 1` on optional-tool-missing) before they ship.
Both read tool input as JSON on stdin (the documented Claude Code
hook convention), not legacy `CLAUDE_FILE_PATH` env vars.

### Layer 6 — Project-level `permissions.deny`
`.claude/settings.json` denies direct `Read`/`Edit` on
`./terraform/.env`, `~/.aws/credentials`, and `~/.aws/config`. Hooks
catch the shell-cmd path; this catches the tool-call path.

### Layer 7 — `block-webfetch.sh` PreToolUse WebFetch/WebSearch hook
Defense against prompt-injection-driven exfiltration. If an agent
reads attacker-controlled content (a malicious README, issue comment,
fetched page) that content can instruct "fetch this URL with
.env contents in the query string" — and the agent will. This hook
denies WebFetch/WebSearch calls targeting known OOB sinks (`oast.live`,
`burpcollaborator`, `webhook.site`, `ngrok`, `requestbin`, `pipedream`)
or carrying credential-shaped query parameters
(`token=`, `api_key=`, `password=`, `secret=`, etc.).

### Layer 8 — Pre-destroy state snapshot
`appserver.sh destroy` snapshots the active terraform state to
`s3://<state-bucket>/state-snapshots/destroy-<UTC-timestamp>.tfstate`
before running `terraform destroy`. Last-resort recovery if the destroy
takes something out it shouldn't have.

### Layer 9 — Least-privilege IAM
The deployer IAM user has a managed-policy allowlist + an explicit deny
on inline policies for the instance role. The instance role itself sits
under a permissions boundary that caps effective permissions even if a
broader policy is attached by mistake.

### Hook self-test
`.claude/hooks/test-hooks.sh` is an assertion harness that feeds
crafted JSON tool inputs into each hook and verifies the right
deny/allow decision for ~110 cases (regression coverage for every
catalogued pattern, plus carefully chosen allow-cases so the hooks
don't false-positive on normal devops work). Wired into the `Validate`
CI workflow alongside `bash -n` and `shellcheck` of `.claude/hooks/*.sh`
— a typo that silently disabled a hook would otherwise be invisible
until something destructive went unblocked.

### Principles
1. **Reduce blast radius first.** A locked-down IAM principal is worth
   ten lectures in CLAUDE.md.
2. **Make the destructive path the explicit one.** If Claude has to
   stop and ask the user to run `terraform destroy`, that's the gate
   working.
3. **Log everything.** When something does go wrong, the question is
   always "what ran in the last 30 minutes?" — make that grep-able.
4. **Hook bypasses are bugs in the hook.** If a destructive op slips
   through, the answer is to add a pattern, not to disable the hook.

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

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (60-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test             # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest              # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk pytest              # Python test failures only (90%)
rtk rake test           # Ruby test failures only (90%)
rtk rspec               # RSpec test failures only (60%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%)
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->