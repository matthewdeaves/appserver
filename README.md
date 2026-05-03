# Appserver

Docker app hosting on a single EC2 instance, routed by Traefik and exposed through a Cloudflare Tunnel. No inbound ports, no SSH keys — access is via AWS SSM only.

Currently hosting [Cookie](https://github.com/matthewdeaves/cookie), a recipe manager with passkey authentication.

> This is the author's personal infrastructure repo, published as a worked example. It is MIT-licensed and forkable — see `CONTRIBUTING.md` for what kinds of changes land upstream and what's better forked. The `terraform.tfvars.example` and `./scripts/appserver.sh setup local` flow document everything you need to fill in for your own deployment.
>
> The repo is also a reference for **operating production infra with Claude Code as the agent**. See the *Blast-radius gates for Claude Code* section in `CLAUDE.md` for the layered hooks and IAM controls that gate destructive operations — written after reading about the [PocketOS / Cursor incident](https://www.tomshardware.com/tech-industry/artificial-intelligence/claude-powered-ai-coding-agent-deletes-entire-company-database-in-9-seconds-backups-zapped-after-cursor-tool-powered-by-anthropics-claude-goes-rogue) where an agent deleted a production database in 9 seconds.

## How It Works

```
Client → Cloudflare → Tunnel → Traefik (:80) → App container
```

- **Compute**: EC2 t4g.small (ARM/Graviton), Amazon Linux 2023
- **Ingress**: Cloudflare Tunnel — zero inbound security group rules
- **Auth**: Cloudflare Access — email OTP for browsers, service token for CLI. AWS-side: per-skill IAM roles assumed via TOTP MFA, 1-hour STS sessions (see "Operator IAM" below).
- **Routing**: Traefik reverse proxy — routes `<app>.matthewdeaves.com` subdomains via Docker labels
- **IaC**: Terraform manages EC2, IAM, Cloudflare Tunnel/DNS/Access, monitoring, and snapshots
- **Monitoring**: $10/month budget alarm, EC2 auto-recovery, daily EBS snapshots (7-day retention)

## Prerequisites

- AWS CLI (configured with credentials)
- Terraform
- jq
- git-crypt (for pentest target configs)
- Cloudflare API token with: Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Zone DNSSEC Edit, Cloudflare Tunnel Edit, Zero Trust Edit

## Getting Started

Your path depends on what already exists in the target AWS account. The three common cases:

| Scenario | What exists in AWS | What you run |
|----------|--------------------|--------------|
| A. Brand-new AWS account | Nothing | `init` → `deploy` → `app init cookie` → `app deploy cookie` |
| B. Joining live infra on a new dev machine | Deployer IAM + state bucket + running EC2 | `aws configure --profile appserver` + `setup local` → `status` |
| C. Rebuilding after a destroy | Deployer IAM + state bucket, but no live infra | `aws configure --profile appserver` + `setup local` → `deploy` → `app init cookie` → `app deploy cookie` |

### A. Brand-new AWS account

Use this only when bootstrapping from an empty AWS account (no `appserver-deployer` IAM user, no state bucket). Requires **admin AWS credentials** on your local default credential chain — the deployer user can't create its own IAM policies.

```bash
./scripts/appserver.sh init              # Creates IAM + state bucket, prompts for CF config
./scripts/appserver.sh deploy            # Provisions EC2 + Cloudflare Tunnel + DNS + Access
./scripts/appserver.sh app init cookie   # Generates Cookie secrets on the instance
./scripts/appserver.sh app deploy cookie # Pulls image + starts the compose stack
```

### B + C. Existing AWS account (most common)

Use these when the deployer IAM user and state bucket already exist (i.e. someone has run `init` at some point). You'll need:

1. **AWS access key + secret** for the `appserver-deployer` IAM user
2. **Cloudflare API token** (Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Zone DNSSEC Edit, Cloudflare Tunnel Edit, Zero Trust Edit) — plus the **zone ID** and **account ID** for your domain (visible on the Cloudflare dashboard)
3. **GitHub SSH key** to clone the repo

Configure the machine:

```bash
git clone git@github.com:matthewdeaves/appserver.git
cd appserver

aws configure --profile appserver        # Paste deployer access key + secret, region (eu-west-2), json
./scripts/appserver.sh setup local       # Interactive prompts → writes terraform/.env + tfvars (no AWS admin)
./scripts/install-git-hooks.sh           # Local pre-commit gitleaks scan (requires gitleaks installed)
```

Check whether live infra exists:

```bash
./scripts/appserver.sh status            # Shows running containers, or "Could not reach instance"
```

- **Scenario B** — `status` shows containers running (Traefik, cloudflared, app). You're done. Use `app deploy cookie` later to ship new Cookie versions.
- **Scenario C** — `status` errors because there's no instance. Rebuild infra:

  ```bash
  ./scripts/appserver.sh deploy            # Re-provisions EC2 + CF resources
  ./scripts/appserver.sh app init cookie   # Re-generates Cookie secrets on the instance
  ./scripts/appserver.sh app deploy cookie # Re-pulls image + starts
  ```

The CLI auto-detects the `appserver` AWS profile if configured. The deployer user has the minimum permissions needed — do not use root for day-to-day work.

**When to run `init`:** only for scenario A, or if a previous `destroy` was run with the "also remove bootstrap" option (which deletes the deployer IAM user + state bucket). `init` is idempotent but requires admin credentials, so it can't run from the `appserver` profile.

### Operator IAM (MFA + per-skill roles)

Day-to-day CLI commands authenticate via three MFA-gated IAM roles, not the long-lived deployer access key:

```bash
./scripts/appserver.sh auth                    # interactive role pick (default: readonly)
./scripts/appserver.sh auth --role deploy      # explicit deploy-role for a terraform apply session
./scripts/appserver.sh auth status             # show active session expiries
```

The CLI maps each subcommand to one of:

- `appserver-readonly-role` — diagnostic only (`status`, `logs`, `spend`, `health`, `app list`, etc.)
- `appserver-cookie-ops-role` — cookie app management (`app deploy/init/remove/restart/env`, `config push`, `threats block/...`)
- `appserver-deploy-role` — full infra changes (`deploy`, `destroy`, `start`, `stop`, `ssh`)

One-time MFA setup per machine:

1. AWS console → IAM → Users → `appserver-deployer` → Security credentials → Assign MFA device (TOTP, e.g. 1Password / Authy)
2. Copy the device ARN into `terraform/.env`:
   ```
   export MFA_SERIAL_NUMBER="arn:aws:iam::<account-id>:mfa/appserver-deployer"
   ```
3. Run `appserver.sh auth` — it'll prompt for the 6-digit code and write a 1-hour session to `~/.aws/credentials`

After the phase-5 cutover the deployer user only holds `AppserverDeployerAssumeRoles` — the long-lived access key on disk can do nothing without an MFA prompt. See `specs/003-iam-mfa-scoping/` for the design.

#### Migrating from the long-lived deployer key

If you forked the repo before the rollout completed:

1. Re-run `./scripts/appserver.sh init` (admin creds) — it'll detach the three legacy policies from the deployer user idempotently.
2. Re-run `./scripts/appserver.sh deploy` to apply the phase-1 terraform additions (3 operator roles + boundaries + iam-ssm tightening).
3. Enrol MFA on `appserver-deployer` (AWS console) and add `MFA_SERIAL_NUMBER=...` to `terraform/.env`.
4. `./scripts/appserver.sh auth` to assume a role; the legacy `appserver` profile is no longer auto-used.

**Things to know about running from multiple machines:**

- **Terraform state locking is not set up.** The S3 backend has no DynamoDB lock table, so two machines running `deploy` simultaneously can corrupt state. Coordinate manually, or add a lock table if this becomes a problem.
- **The deployer key has a large blast radius** — full infra control plus Cookie admin via SSM. Scope vault access accordingly and rotate on a schedule.
- **Consider one Cloudflare token per machine** rather than sharing one, so tokens can be revoked individually if a laptop is lost.

### Pentest target configs

Pentest target YAMLs (`pentest/targets/*.yaml`) are encrypted via git-crypt. They contain attack surface details, rate limits, and vulnerability history. The `.example` files are unencrypted templates.

- `setup unlock` — decrypt using key from SSM (requires `ssm:GetParameter` on `/appserver/*`)
- `setup unlock /path/to/key` — decrypt using a local key file
- `setup lock` — re-encrypt files in working tree

## CLI Reference

```
appserver.sh auth [--role <r>]     Assume an IAM role via MFA (1-hour STS session)
appserver.sh auth status           Show active role sessions

appserver.sh init                  Bootstrap AWS infra (IAM + state bucket, admin creds)
appserver.sh deploy                Terraform apply + upload config to S3
appserver.sh destroy               Terraform destroy + optional cleanup
appserver.sh status                Running containers + resource usage
appserver.sh start / stop          EC2 instance power management
appserver.sh ssh                   SSM session to instance
appserver.sh logs [app]            Container logs
appserver.sh spend                 AWS cost breakdown

appserver.sh app init <name>       Generate secrets + .env on instance
appserver.sh app deploy <name>     Pull image + restart
appserver.sh app list              All apps + status
appserver.sh app remove <name>     Stop + remove (preserves volumes)
appserver.sh app restart <name>    Restart app containers
appserver.sh app env <name>        View/set environment variables

appserver.sh config push           Push config + restart Traefik
appserver.sh config check-ips      Audit Cloudflare IP ranges in traefik.yml

appserver.sh setup local           Write terraform/.env + tfvars (for existing infra)
appserver.sh setup unlock          Decrypt pentest targets (key from SSM)
appserver.sh setup lock            Re-encrypt pentest targets

appserver.sh threats               Analyze access logs for threats (last 24h)
appserver.sh threats block <ip>    Block IP via Cloudflare WAF
appserver.sh threats blocked       List blocked IPs
appserver.sh threats allow [<ip>]  Allowlist IP in CF WAF (defaults to public IP; for pentests)
appserver.sh threats allowed       List allowlisted IPs
```

## Adding an App

1. Add the subdomain to `app_subdomains` in `terraform/terraform.tfvars`
2. Create `config/apps/<name>/docker-compose.yml` with Traefik labels and the `appserver` network
3. Create `config/apps/<name>/.env.example` with placeholder secrets
4. `appserver.sh deploy` → `app init <name>` → `app deploy <name>`

## Project Layout

```
terraform/          Infrastructure (EC2, IAM, Cloudflare Tunnel/DNS/Access, WAF, monitoring, snapshots)
config/traefik/     Traefik reverse proxy config + compose + HSTS middleware
config/apps/        Per-app Docker Compose stacks + env examples
scripts/            appserver.sh (admin CLI) + bootstrap.sh (EC2 user_data)
pentest/            Cookie-specific config (target YAMLs, hooks, ai+webauthn modules); generic engine in pentest-kit (sibling clone), invoked via /pentest skill
.claude/            Claude Code config: blast-radius hooks (block-destructive, block-credential-reads, block-webfetch), audit-bash, hook self-test harness
.github/            CI: terraform fmt/validate, tfsec, shellcheck, gitleaks, dependency-review, hook self-test
```

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and security review findings.

## License

[MIT](LICENSE). See `CONTRIBUTING.md` for upstream-vs-fork guidance.
