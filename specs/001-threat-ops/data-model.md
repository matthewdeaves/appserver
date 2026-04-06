# Data Model: Threat Analysis & Response

## Entities

### ThreatReport

The top-level output of a threat analysis run. One report per analysis invocation.

| Field | Type | Description |
|-------|------|-------------|
| timestamp | ISO 8601 string | When the analysis was run |
| time_window | string | Analysis period (e.g., "24h", "1h") |
| log_entries_analyzed | integer | Total access log lines processed |
| unique_ips | integer | Distinct client IPs seen |
| total_requests | integer | Total HTTP requests in window |
| findings | Finding[] | Detected threat patterns |
| recommendations | Recommendation[] | Suggested defensive actions |
| cf_edge | CFEdgeData? | Optional Cloudflare edge data (null if unavailable) |
| status | enum | "clean" (no threats), "threats_detected", "error" |

### Finding

A single detected threat pattern, grouped by IP or attack category.

| Field | Type | Description |
|-------|------|-------------|
| id | string | Unique finding ID (e.g., "F-001") |
| category | enum | "path_scan", "auth_brute_force", "traversal", "scanner_ua", "high_rate", "suspicious" |
| severity | enum | "critical", "high", "medium", "low", "info" |
| ip | string | Source IP address (from CF-Connecting-IP) |
| count | integer | Number of matching requests |
| sample_paths | string[] | Up to 5 example request paths |
| sample_ua | string | User agent string |
| first_seen | ISO 8601 string | Earliest matching request |
| last_seen | ISO 8601 string | Latest matching request |
| status_codes | object | Map of HTTP status code to count (e.g., {"404": 812, "403": 35}) |

**Category definitions**:
- `path_scan`: Requests to known probe paths (/wp-admin, /.env, etc.)
- `auth_brute_force`: High volume of requests to authentication endpoints
- `traversal`: Directory traversal patterns in request path
- `scanner_ua`: Known scanner/tool user agent signature
- `high_rate`: Abnormally high request rate from single IP (>100 req in window)
- `suspicious`: Doesn't match a specific category but has anomalous characteristics

**Severity assignment**:
- `critical`: Active exploitation attempt (traversal + 200 status, auth brute force with some 200s)
- `high`: Aggressive scanning (>500 requests, multiple attack categories)
- `medium`: Moderate scanning (50-500 requests, single category)
- `low`: Light probing (<50 requests, common scanner patterns)
- `info`: Informational (unusual but not clearly malicious)

### Recommendation

An actionable defensive measure derived from one or more findings.

| Field | Type | Description |
|-------|------|-------------|
| id | string | Unique recommendation ID (e.g., "R-001") |
| action | enum | "block_ip", "rate_limit", "monitor", "investigate" |
| target | string | IP address, CIDR, or endpoint pattern |
| rationale | string | Why this action is recommended (references finding IDs) |
| confidence | enum | "high", "medium", "low" |
| finding_ids | string[] | Related finding IDs |

**Action definitions**:
- `block_ip`: Create Cloudflare IP access rule to block this IP
- `rate_limit`: Suggest a new rate limiting rule for an endpoint pattern
- `monitor`: Flag for continued observation (not actionable yet)
- `investigate`: Ambiguous pattern, needs human review

**Confidence assignment**:
- `high`: Clear scanner signature + high volume + only 4xx responses → safe to block
- `medium`: Suspicious pattern but could be legitimate (e.g., automated monitoring tool)
- `low`: Ambiguous, needs human judgment

### Action

Records an enacted recommendation for audit trail.

| Field | Type | Description |
|-------|------|-------------|
| timestamp | ISO 8601 string | When the action was taken |
| recommendation_id | string | Which recommendation was enacted |
| action_type | enum | "block_ip", "rate_limit" |
| target | string | IP or endpoint affected |
| cf_rule_id | string | Cloudflare rule ID created |
| result | enum | "success", "failed", "already_exists" |
| error | string? | Error message if failed |

### CFEdgeData (Optional)

Cloudflare-side visibility, when Analytics:Read permission is available.

| Field | Type | Description |
|-------|------|-------------|
| available | boolean | Whether CF analytics data was retrieved |
| waf_blocks | integer | WAF block events in the time window |
| rate_limit_triggers | integer | Rate limiting blocks in the window |
| bot_score_distribution | object | Map of bot score ranges to request counts |
| top_blocked_ips | object[] | IPs blocked at edge with count and reason |

## Relationships

```
ThreatReport 1──* Finding
ThreatReport 1──* Recommendation
Recommendation *──* Finding (via finding_ids)
Action *──1 Recommendation (via recommendation_id)
ThreatReport 0──1 CFEdgeData
```

## State Transitions

### ThreatReport Lifecycle
```
analysis_started → analyzing → complete (clean | threats_detected) | error
```

### Recommendation Lifecycle
```
proposed → enacted | dismissed | expired
```
- `proposed`: Initial state from analysis
- `enacted`: Action taken via skill (has corresponding Action record)
- `dismissed`: Operator reviewed and chose not to act
- `expired`: Report aged out without action (informational)

## File Storage Layout

```
reports/threats/
├── 20260406-143000/
│   ├── report.json          # Full ThreatReport as JSON
│   ├── SUMMARY.md           # Human-readable summary
│   └── actions.json         # Actions taken (appended as enacted)
├── 20260407-090000/
│   ├── report.json
│   ├── SUMMARY.md
│   └── actions.json
└── ...
```
