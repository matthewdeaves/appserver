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

## Security Reviews

Independent security reviews are tracked via GitHub issues:

- **Issue #3** — Infrastructure review (AWS, Cloudflare, Terraform, Traefik, bootstrap)
- **Issue #6** — Application review (Cookie: Django, React, legacy frontend, AI)

### Infrastructure findings (Issue #3)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| HIGH-1 | High | Deployer IAM inline policy escalation | **Fixed** — managed-policy-only design + deny on instance role + permissions boundary |
| MED-1 | Medium | Terraform state holds sensitive material | **Hardened** — S3 encryption, principal-restricted bucket policy, versioning |
| MED-2 | Medium | Bootstrap Traefik trustedIPs divergence | **Fixed** — synchronized with canonical config |
| MED-3 | Medium | Docker Compose plugin unpinned | **Fixed** — pinned version + SHA256 verification |
| LOW-1 | Low | `home_ip` Cloudflare Access bypass | **Accepted** — conditional, empty by default, single-tenant convenience |
| LOW-2 | Low | Traefik Docker socket (read-only) | **Accepted** — standard Traefik requirement, single-tenant deployment |

### Application findings (Issue #6 — Cookie repo scope)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| APP-MED-1 | Medium | Legacy frontend `innerHTML` XSS risk | Cookie repo — server-side nh3 sanitization added (v1.26.0) |
| APP-MED-2 | Medium | CSP `style-src 'unsafe-inline'` | Cookie repo — removed in v1.26.0 |
| APP-MED-3 | Medium | No dependency-review on PRs | **Fixed** — added to both repos' CI |
| APP-LOW-1 | Low | CSRF cookie not HttpOnly | **Accepted** — SPA design requirement |
| APP-LOW-2 | Low | AI prompt injection surface | **Accepted** — output is display-only, no privileged actions |

### Accepted risks

**LOW-1: `home_ip` bypass** — When `home_ip` is set in terraform.tfvars, requests from that IP bypass Cloudflare Access email OTP. This is a deliberate single-tenant convenience. Mitigation: variable defaults to empty; only one IP; operator must explicitly configure.

**LOW-2: Docker socket** — Traefik requires Docker socket access for container discovery. Mounted read-only. Risk is inherent to Docker provider pattern. Mitigation: single-tenant deployment, no inbound ports, Traefik is the only consumer.
