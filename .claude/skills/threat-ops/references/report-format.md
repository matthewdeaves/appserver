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
  "cf_edge": null
}
```

### Status Values

- `clean`: No threats detected in the time window
- `threats_detected`: One or more findings generated
- `error`: Analysis failed (no logs, SSM failure, etc.)

### Finding Categories

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
