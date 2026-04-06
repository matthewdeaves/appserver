# Research: Threat Analysis & Response

## R1: Traefik Access Log Configuration

**Decision**: Enable JSON-format access logs with Cloudflare header preservation.

**Rationale**: JSON is machine-parseable by jq on the instance. Traefik's default JSON access log includes all needed fields (ClientHost, RequestMethod, RequestPath, DownstreamStatus, request_User-Agent, StartUTC). The `CF-Connecting-IP` header contains the real client IP (Traefik sees the tunnel IP otherwise). Traefik supports `headers.names` field configuration to include/drop specific headers.

**Alternatives considered**:
- CLF (Common Log Format): Human-readable but harder to parse reliably with jq. Rejected.
- No access logs, rely on Cloudflare Analytics API only: Requires paid plan for detailed logs. Rejected.

**Configuration pattern**:
```yaml
accessLog:
  filePath: /var/log/traefik/access.log
  format: json
  fields:
    headers:
      defaultMode: drop
      names:
        CF-Connecting-IP: keep
        User-Agent: keep
```

## R2: Cloudflare API for IP Blocking

**Decision**: Use Cloudflare IP Access Rules API (`/zones/{zone_id}/firewall/access_rules/rules`).

**Rationale**: This is the simplest Cloudflare mechanism for blocking individual IPs. Supports `block`, `challenge`, `whitelist` modes. Free tier supports up to 50,000 IP access rules. No Terraform needed — purely operational via REST API.

**API pattern**:
```bash
# Block an IP
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"mode":"block","configuration":{"target":"ip","value":"1.2.3.4"},"notes":"threat-ops: scanning"}'

# List existing blocks
curl "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules?mode=block&page=1&per_page=50"

# Delete a block
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules/$RULE_ID"
```

**Permissions required**: Zone WAF Edit (already in the API token per CLAUDE.md).

**Alternatives considered**:
- Custom WAF rules (cloudflare_ruleset): More powerful expressions but limited to 5 rules on free plan. Better for patterns than individual IPs. Rejected for IP blocking, may use for rate limiting.
- Terraform-managed rules: Inappropriate for dynamic, ephemeral IP blocks. Rejected.

## R3: SSM Output Size Limits

**Decision**: Run analysis on-instance, return JSON summary via SSM. Use S3 as overflow for large reports.

**Rationale**: SSM `get-command-invocation` returns up to ~24KB of stdout inline. A compact JSON threat report (top 20 IPs, findings, recommendations) fits within this limit. For verbose output (full log excerpts), write to a temp file on the instance and retrieve via S3 if needed.

**Pattern**:
```bash
# On-instance analysis (via ssm_run):
jq -s '...' /var/log/traefik/access.log | head -c 20000
# If over limit, write to /tmp/threat-report.json and fetch via S3
```

## R4: Known Scanner Path Database

**Decision**: Maintain a curated list in the skill's reference file, used by the analysis script.

**Rationale**: The list of known probe paths is well-established and rarely changes. Embedding it in the analysis script as an array keeps things self-contained. The skill reference file documents what each pattern detects and why.

**Core patterns**:
- WordPress: `/wp-admin`, `/wp-login.php`, `/wp-content`, `/xmlrpc.php`
- Config files: `/.env`, `/.git`, `/config.yml`, `/composer.json`, `/package.json`
- Admin panels: `/phpmyadmin`, `/adminer`, `/admin`, `/cpanel`, `/webmail`
- Shell access: `/shell`, `/cmd`, `/console`, `/terminal`, `/cgi-bin`
- Traversal: `../`, `..%2f`, `..%252f`
- Known CVEs: `/solr/`, `/actuator`, `/api/v1/pods`, `/.well-known/`

**Scanner user agents**:
- `sqlmap`, `nikto`, `nmap`, `masscan`, `zgrab`, `Nuclei`, `dirbuster`, `gobuster`, `ffuf`, `wfuzz`
- Generic: `python-requests`, `Go-http-client`, `curl/` (without a plausible referer)

## R5: Log Rotation Strategy

**Decision**: Daily rotation, 14-day retention, compressed, ~500MB budget.

**Rationale**: At low traffic (~1KB per JSON log entry, ~1000 requests/day), daily logs are ~1MB uncompressed. During active scanning, this could spike to 10-50MB/day. 14 days × 50MB compressed ≈ ~100MB worst case, well within the 500MB budget. Daily rotation keeps individual files manageable for jq processing.

**Logrotate config**:
```
/var/log/traefik/access.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  create 0644 root root
}
```

Note: `copytruncate` is needed because Traefik holds the file open (no SIGHUP reload for access logs). This avoids needing to restart Traefik on rotation.

## R6: Cloudflare Analytics API (Optional Enhancement)

**Decision**: Support as optional enrichment when CF token has `Analytics:Read` permission.

**Rationale**: The Cloudflare GraphQL Analytics API (`/graphql`) can provide WAF events, bot scores, and rate limit triggers. This gives visibility into what Cloudflare blocked at the edge before traffic reached the server. However, the free plan has limited analytics retention (24h) and the API requires a separate permission scope.

**Pattern**: Test permission with a lightweight query first; if 403, skip silently and note in report.
