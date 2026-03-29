# Security Policy

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

To report a vulnerability, use [GitHub's private vulnerability reporting](https://github.com/matthewdeaves/appserver/security/advisories/new). This ensures the report stays confidential until a fix is available.

If private reporting is unavailable (e.g. while the repo is private), email **security@matthewdeaves.com** with:

- Description of the vulnerability
- Steps to reproduce
- Affected components (Terraform, bootstrap script, Traefik config, app configs)
- Potential impact

You should receive an acknowledgement within 48 hours.

## Scope

This repo manages infrastructure and deployment configuration. Relevant security concerns include:

- IAM policy or security group misconfigurations
- Secrets exposure in config files, scripts, or Terraform state
- Cloudflare Tunnel or Access policy bypasses
- Container escape or privilege escalation via Docker Compose configs
- Script injection in `appserver.sh` or `bootstrap.sh`

Issues in upstream software (Docker, Traefik, Cloudflare, AWS) should be reported to those projects directly.
