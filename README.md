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
- Cloudflare API token with: Zone DNS Edit, Zone Settings Edit, Zone WAF Edit, Cloudflare Tunnel Edit, Zero Trust Edit

## Quick Start

```bash
./scripts/appserver.sh init              # Interactive setup (IAM, state bucket, tfvars)
./scripts/appserver.sh deploy            # Provision infrastructure
./scripts/appserver.sh app init cookie   # Generate secrets on instance
./scripts/appserver.sh app deploy cookie # Pull image + start
```

## CLI Reference

```
appserver.sh init                  Interactive first-time setup
appserver.sh deploy                Terraform apply (auto-uploads config)
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
```

## Adding an App

1. Add the subdomain to `app_subdomains` in `terraform/terraform.tfvars`
2. Create `config/apps/<name>/docker-compose.yml` with Traefik labels and the `appserver` network
3. Create `config/apps/<name>/.env.example` with placeholder secrets
4. `appserver.sh deploy` → `app init <name>` → `app deploy <name>`

## Project Layout

```
terraform/          Infrastructure (EC2, IAM, Cloudflare Tunnel/DNS/Access, WAF, monitoring, snapshots)
config/traefik/     Traefik reverse proxy config + compose
config/apps/        Per-app Docker Compose stacks + env examples
scripts/            appserver.sh (admin CLI) + bootstrap.sh (EC2 user_data)
.github/            CI (terraform fmt/validate, shellcheck, gitleaks) + Dependabot config
```

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

Private repository. All rights reserved.
