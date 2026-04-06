# Quickstart: Threat Analysis & Response

## Prerequisites

- appserver deployed and running (`./scripts/appserver.sh status` shows healthy)
- `CLOUDFLARE_API_TOKEN` set in environment (needs Zone WAF Edit permission)
- `jq` installed locally

## Setup (one-time)

1. Deploy the updated Traefik config with access logging enabled:
   ```bash
   ./scripts/appserver.sh config push
   ```

2. Verify access logs are being written (wait a few minutes for traffic):
   ```bash
   ./scripts/appserver.sh ssh
   # On instance:
   ls -la /var/log/traefik/access.log
   tail -5 /var/log/traefik/access.log
   ```

## Usage

### Run threat analysis
```bash
./scripts/appserver.sh threats                # Analyze last 24h
./scripts/appserver.sh threats --since 1h     # Analyze last hour
```

### Review reports
```bash
./scripts/appserver.sh threats report         # View latest report
./scripts/appserver.sh threats list           # List all reports
```

### Block a threatening IP
```bash
./scripts/appserver.sh threats block 45.33.32.156 --note "scanner: zgrab"
```

### Check what's blocked
```bash
./scripts/appserver.sh threats blocked
```

### Unblock an IP
```bash
./scripts/appserver.sh threats unblock 45.33.32.156
```

### Via Claude Code skill
```
/threat-ops                    # Run full analysis
/threat-ops review             # Review latest report
/threat-ops block 1.2.3.4     # Block an IP
/threat-ops status             # Show blocked IPs
```

## What It Detects

| Category | Examples | Severity |
|----------|----------|----------|
| Path scanning | /wp-admin, /.env, /phpmyadmin | Medium-High |
| Auth brute force | Rapid POSTs to /api/auth/* | High-Critical |
| Directory traversal | ../ in request paths | High-Critical |
| Scanner user agents | sqlmap, nikto, zgrab, nuclei | Medium-High |
| High request rate | >100 requests from single IP | Medium |
