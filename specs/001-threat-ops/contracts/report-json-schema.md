# Contract: Threat Report JSON Schema

## `report.json`

```json
{
  "timestamp": "2026-04-06T14:30:00Z",
  "time_window": "24h",
  "log_entries_analyzed": 4521,
  "unique_ips": 87,
  "total_requests": 4521,
  "status": "threats_detected",
  "findings": [
    {
      "id": "F-001",
      "category": "path_scan",
      "severity": "high",
      "ip": "45.33.32.156",
      "count": 847,
      "sample_paths": ["/wp-login.php", "/.env", "/phpmyadmin", "/admin", "/.git/config"],
      "sample_ua": "Mozilla/5.0 zgrab/0.x",
      "first_seen": "2026-04-05T15:22:01Z",
      "last_seen": "2026-04-06T14:12:33Z",
      "status_codes": {"404": 812, "403": 35}
    }
  ],
  "recommendations": [
    {
      "id": "R-001",
      "action": "block_ip",
      "target": "45.33.32.156",
      "rationale": "Pure scanner: 847 requests, 100% error responses, zgrab user agent (F-001)",
      "confidence": "high",
      "finding_ids": ["F-001"]
    }
  ],
  "cf_edge": null
}
```

## `actions.json`

Append-only log of enacted recommendations.

```json
[
  {
    "timestamp": "2026-04-06T14:35:00Z",
    "recommendation_id": "R-001",
    "action_type": "block_ip",
    "target": "45.33.32.156",
    "cf_rule_id": "abc123def456",
    "result": "success",
    "error": null
  }
]
```

## `SUMMARY.md`

Human-readable report following this structure:

```markdown
# Threat Report: 2026-04-06 14:30

**Window**: Last 24 hours | **Requests**: 4,521 | **Unique IPs**: 87 | **Status**: THREATS DETECTED

## Findings (3 threats)

### [HIGH] F-001: Path scanning from 45.33.32.156
- **Requests**: 847 (404: 812, 403: 35)
- **Paths**: /wp-login.php, /.env, /phpmyadmin, /admin, /.git/config
- **User Agent**: Mozilla/5.0 zgrab/0.x
- **Window**: 2026-04-05 15:22 — 2026-04-06 14:12

## Recommendations

| ID | Action | Target | Confidence | Rationale |
|----|--------|--------|------------|-----------|
| R-001 | block_ip | 45.33.32.156 | high | Pure scanner: 847 requests, 100% errors, zgrab UA |

## Actions Taken

_No actions taken yet. Use `appserver.sh threats block <ip>` or the threat-ops skill to enact recommendations._
```
