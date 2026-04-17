# Appserver

Docker app hosting on a single EC2 instance, routed by Traefik and exposed through a Cloudflare Tunnel. No inbound ports, no SSH keys — access is via AWS SSM only.

Currently hosting [Cookie](https://github.com/matthewdeaves/cookie), a recipe manager with passkey authentication.

## How It Works

```
Client → Cloudflare → Tunnel → Traefik (:80) → App container
```

- **Compute**: EC2 t4g.small (ARM/Graviton), Amazon Linux 2023
- **Ingress**: Cloudflare Tunnel — zero inbound security group rules
- **Auth**: Cloudflare Access — email OTP for browsers, service token for CLI
- **Routing**: Traefik reverse proxy — routes `<app>.matthewdeaves.com` subdomains via Docker labels
- **IaC**: Terraform manages EC2, IAM, Cloudflare Tunnel/DNS/Access, monitoring, and snapshots
- **Monitoring**: $10/month budget alarm, EC2 auto-recovery, daily EBS snapshots (7-day retention)

## Prerequisites

- AWS CLI (configured with credentials)
- Terraform
- jq
- git-crypt (for pentest target configs)
- Cloudflare API token with: Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Cloudflare Tunnel Edit, Zero Trust Edit

## Getting Started

### First-time infrastructure setup

```bash
./scripts/appserver.sh init              # Interactive setup (IAM, state bucket, tfvars)
./scripts/appserver.sh deploy            # Provision infrastructure
./scripts/appserver.sh app init cookie   # Generate secrets on instance
./scripts/appserver.sh app deploy cookie # Pull image + start
```

### Joining an existing deployment

If the infrastructure is already running and you're setting up a new dev machine, you'll need three secrets from your password vault:

1. **AWS access key + secret** for the `appserver-deployer` IAM user (gives Terraform, SSM, and S3 state access)
2. **Cloudflare API token** with Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Cloudflare Tunnel Edit, Zero Trust Edit
3. **GitHub SSH key or PAT** to clone the repo

Then:

```bash
git clone git@github.com:matthewdeaves/appserver.git
cd appserver

# 1. AWS credentials for the deployer IAM user (not root)
aws configure --profile appserver
# Paste the appserver-deployer access key ID and secret access key

# 2. Cloudflare API token — put it in terraform/.env (gitignored, per-machine)
cp terraform/.env.example terraform/.env
# Edit terraform/.env and replace the placeholder token.
# Keep the `export` prefix — the CLI sources this file and the var needs to
# reach Terraform/curl subprocesses.

# 3. Decrypt pentest target configs (key is fetched from SSM automatically)
./scripts/appserver.sh setup unlock

# Smoke test
./scripts/appserver.sh status
```

The CLI auto-detects the `appserver` AWS profile if configured. The deployer user has the minimum permissions needed — do not use root for day-to-day work.

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
appserver.sh init                  Interactive first-time setup
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

appserver.sh setup unlock          Decrypt pentest targets (key from SSM)
appserver.sh setup lock            Re-encrypt pentest targets

appserver.sh threats               Analyze access logs for threats (last 24h)
appserver.sh threats block <ip>    Block IP via Cloudflare WAF
appserver.sh threats blocked       List blocked IPs
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
pentest/            Penetration testing toolkit (14 modules, invoke via /pentest skill)
.github/            CI (terraform fmt/validate, tfsec, shellcheck, gitleaks, dependency-review)
```

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting and security review findings.

## License

Private repository. All rights reserved.
