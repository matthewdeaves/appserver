# Report Format Reference

## Directory Layout

```
reports/threats/
├── 20260406-143000/
│   ├── report.json      # Machine-readable full report
│   ├── SUMMARY.md       # Human-readable summary
│   └── actions.json     # Audit trail of enacted recommendations
├── 20260407-090000/
│   ├── report.json
│   ├── SUMMARY.md
│   └── actions.json
└── ...
```

- Directory names are UTC timestamps: `YYYYMMDD-HHMMSS`
- The entire `reports/threats/` directory is gitignored
- Reports are local-only (contain IP addresses and security findings)

## report.json Schema

```json
{
  "timestamp": "2026-04-06T14:30:00Z",
  "time_window": "24h",
  "log_entries_analyzed": 4521,
  "unique_ips": 87,
  "total_requests": 4521,
  "status": "clean | threats_detected | error",
  "findings": [
    {
      "id": "F-001",
      "category": "path_scan | auth_brute_force | traversal | scanner_ua | high_rate | suspicious",
      "severity": "critical | high | medium | low | info",
      "ip": "45.33.32.156",
      "count": 847,
      "sample_paths": ["/wp-login.php", "/.env"],
      "sample_ua": "Mozilla/5.0 zgrab/0.x",
      "first_seen": "2026-04-05T15:22:01Z",
      "last_seen": "2026-04-06T14:12:33Z",
      "status_codes": {"404": 812, "403": 35}
    }
  ],
  "recommendations": [
    {
      "id": "R-001",
      "action": "block_ip | rate_limit | monitor | investigate",
      "target": "45.33.32.156",
      "rationale": "Pure scanner: 847 requests, 100% errors, zgrab UA (F-001)",
      "confidence": "high | medium | low",
      "finding_ids": ["F-001"]
    }
  ],
  "cf_edge": {
    "available": true,
    "waf_blocks": 142,
    "rate_limit_triggers": 23,
    "top_blocked_ips": [{"ip": "1.2.3.4", "count": 88}]
  },
  "app_security": {
    "audit_ok": true,
    "event_count": 12,
    "recent_registrations": 0,
    "recent_logins": 3,
    "events_sample": [
      {"type": "passkey_login", "username": "pk_0fc0e1dc", "timestamp": "2026-04-06T12:00:00Z"}
    ]
  },
  "app_errors": {
    "nginx_5xx": 0,
    "nginx_4xx": 45,
    "top_error_paths": [
      {"path": "/api/recipes/999/", "count": 12}
    ]
  },
  "container_events": {
    "restarts": []
  },
  "tunnel_health": {
    "warnings": []
  },
  "cost_anomaly": {
    "available": true,
    "yesterday": 0.42,
    "day_before": 0.41,
    "currency": "USD",
    "anomaly": "normal | elevated | spike"
  }
}
```

### Status Values

- `clean`: No Traefik-layer threats detected (app_security/cost fields are informational)
- `threats_detected`: One or more Traefik findings generated
- `error`: Analysis failed (no logs, SSM failure, etc.)

### Finding Categories (Traefik layer)

- `path_scan`: Requests to known probe paths
- `auth_brute_force`: High volume to auth endpoints
- `traversal`: Directory traversal patterns in paths
- `scanner_ua`: Known scanner user agent signature
- `high_rate`: >100 requests from single IP in window
- `suspicious`: Anomalous but uncategorized

### Recommendation Actions

- `block_ip`: Create CF WAF IP access rule to block
- `rate_limit`: Suggest rate limiting rule for endpoint
- `monitor`: Flag for continued observation
- `investigate`: Ambiguous, needs human review

### cf_edge

Populated when `CLOUDFLARE_API_TOKEN` is set and the token has **Account Analytics → Read** permission. If missing permission, `cf_edge` is `null`.

### app_security

Cookie `cookie_admin audit` data. `audit_ok: false` means cookie-web was not running or the command failed. `event_count` and registration/login counts reflect the last 200 audit events (not strictly time-windowed).

### app_errors

Nginx access log summary from the last 2000 lines inside `cookie-web`. Counts 4xx and 5xx responses and surfaces the top error paths. `null` if cookie-web is not running.

### container_events

Docker `die` and `oom` events during the analysis window. Non-empty `restarts` list indicates containers crashed — potential DoS or resource exhaustion. Check which container name appears.

### tunnel_health

cloudflared systemd journal warnings/errors during the window. Reconnection storms suggest instability or upstream Cloudflare issue.

### cost_anomaly

- `anomaly: "normal"` — spend is within expected range
- `anomaly: "elevated"` — yesterday > $2.00 (above typical baseline)
- `anomaly: "spike"` — yesterday > 1.5× the day before — investigate for unauthorized compute

## actions.json Schema

Append-only audit log of enacted recommendations:

```json
[
  {
    "timestamp": "2026-04-06T14:35:00Z",
    "recommendation_id": "R-001",
    "action_type": "block_ip",
    "target": "45.33.32.156",
    "cf_rule_id": "abc123def456",
    "result": "success | failed | already_exists",
    "error": null
  }
]
```

## SUMMARY.md Structure

```markdown
# Threat Report: 2026-04-06 14:30

**Window**: Last 24h | **Requests**: 4,521 | **Unique IPs**: 87 | **Status**: THREATS DETECTED

## Findings (3 threats)

### [HIGH] F-001: path scan from 45.33.32.156
- **Requests**: 847 (404: 812, 403: 35)
- **Paths**: /wp-login.php, /.env, /phpmyadmin
- **User Agent**: Mozilla/5.0 zgrab/0.x
- **Window**: 2026-04-05 15:22 — 2026-04-06 14:12

## Recommendations

| ID | Action | Target | Confidence | Rationale |
|----|--------|--------|------------|-----------|
| R-001 | block_ip | 45.33.32.156 | high | Pure scanner |

## Cloudflare Edge (if available)
- WAF Blocks: 142
- Rate Limit Triggers: 23

## App Security
- **Registrations (window)**: 0
- **Auth events (window)**: 3
- **App 5xx errors** (last 2000 nginx lines): 0
- **App 4xx errors** (last 2000 nginx lines): 45

## Container Events (if any)
2026-04-06T12:00:00Z cookie-web die exit=1

## Tunnel Warnings (if any)
Apr 06 12:00:00 cloudflared[1234]: WARN retry

## Cost Check
- **Yesterday**: 0.42 USD
- **Day before**: 0.41 USD
- **Status**: normal

## Actions Taken
_No actions taken yet._
```

## How to Interpret Findings

- **Critical**: Active exploitation — block immediately
- **High**: Aggressive scanning — block recommended with high confidence
- **Medium**: Moderate scanning — review before blocking
- **Low**: Light probing — monitor, don't block
- **Info**: Unusual but not clearly malicious — informational only

High error ratios (>90% 4xx responses) indicate the scanner is hitting paths that don't exist — safe to block. Low error ratios suggest mixed legitimate/malicious traffic — investigate before blocking.

For **app_security**: unexpected registrations (especially multiple in a short window) warrant investigation via `cookie_admin audit --json --lines 200`. Single legitimate users registering is expected.

For **cost_anomaly spike**: run `./scripts/appserver.sh spend` for a detailed breakdown. Check CloudTrail for unauthorized API calls if spend is unexpected.
