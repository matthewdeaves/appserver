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
| F-21 | Low | Apex HSTS missing (first-visit plaintext window) | **Actionable in Cloudflare dashboard** — apex + www proxy toggle, see runbook below. Out of scope for this repo's Terraform (static site is hosted on GitHub Pages, unrelated to appserver). |

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

## F-21 Apex HSTS (Cloudflare dashboard action)

Found by pentest round 7 (2026-04-20). `cookie.matthewdeaves.com` advertises `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`, but that policy is scoped to the `cookie` subdomain. The apex `matthewdeaves.com` and `www.matthewdeaves.com` are served directly by GitHub Pages (grey-cloud DNS; no Cloudflare proxy), so the zone-level HSTS setting in `terraform/security.tf` (`cloudflare_zone_setting.security_header`) never reaches them. First-time visits to `http://matthewdeaves.com/` are therefore not HSTS-protected.

### Why this isn't Terraform-managed in this repo

The apex is a static GitHub Pages site — unrelated to the EC2/Traefik/Tunnel stack this repo manages. Pulling its DNS records into appserver's Terraform would couple two independent systems. The fix is a one-time Cloudflare dashboard toggle; the regression is caught by `pentest/scripts/headers.sh` regardless of how the fix is applied.

### Preconditions

- Cloudflare zone SSL/TLS mode should be **Full** or **Full (strict)**. GitHub Pages serves HTTPS on its origin IPs with a valid Let's Encrypt cert for the custom domain (verified 2026-04-20: `LE R13 CN=matthewdeaves.com`). Flexible mode would break the origin hop. Check via CF dashboard → SSL/TLS → Overview.

### Steps

1. Cloudflare dashboard → zone `matthewdeaves.com` → **DNS → Records**.
2. For the four apex A records pointing to `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`: click the **grey cloud** icon next to each. It turns **orange** (proxy enabled).
3. For the `www` CNAME pointing to `matthewdeaves.github.io`: same — grey cloud → orange cloud.
4. Save. Propagation is near-instant at the CF edge.

### Validate

```bash
curl -sSI https://matthewdeaves.com/ \
  | grep -iE '^(strict-transport-security|cf-ray|server):'
# expect: cf-ray: <...>           (proxy is ON)
#         strict-transport-security: max-age=63072000; includeSubDomains; preload
#         server: cloudflare
```

And from the curated suite:

```bash
./pentest/pentest.sh run appserver --module headers
```

The `Apex HSTS (F-21, round 7)` section should report `[PASS]` for both apex and www.

### Once stable for 4+ weeks

Submit `matthewdeaves.com` to https://hstspreload.org/. Browser preload takes ~8 weeks to roll out; after that, every Chromium/Firefox/Safari/Edge user gets the apex HSTS-protected on first visit, permanently.

### Rollback

If the apex starts serving errors (e.g. CF SSL-to-origin handshake fails on the GitHub Pages hop): click the orange cloud back to grey on each record. DNS-only resolution restores the pre-fix direct-to-GitHub behaviour immediately. No Terraform state to unwind; GitHub Pages origin is unaffected throughout.
