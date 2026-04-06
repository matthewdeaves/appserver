# CLI Contract: `appserver.sh threats` Subcommand

## Commands

### `appserver.sh threats [--since <duration>]`

Run threat analysis on access logs.

**Arguments**:
- `--since <duration>`: Analysis time window. Default: `24h`. Accepts: `1h`, `6h`, `12h`, `24h`, `7d`.

**Output**: Writes `report.json` and `SUMMARY.md` to `reports/threats/<timestamp>/`. Prints summary to stdout.

**Exit codes**:
- `0`: Analysis complete, no threats (clean)
- `1`: Analysis complete, threats detected
- `2`: Error (no logs, SSM failure, etc.)

**Example**:
```bash
./scripts/appserver.sh threats              # Last 24h
./scripts/appserver.sh threats --since 1h   # Last hour
```

---

### `appserver.sh threats report [<timestamp>]`

View a threat report.

**Arguments**:
- `<timestamp>`: Optional. Specific report timestamp directory. Default: latest report.

**Output**: Prints SUMMARY.md content to stdout.

**Exit codes**:
- `0`: Report found and displayed
- `1`: No reports found

---

### `appserver.sh threats list`

List all available threat reports.

**Output**: Table of timestamp, status, finding count, recommendation count.

**Exit codes**:
- `0`: Reports listed (or empty list)

---

### `appserver.sh threats block <ip> [--note <reason>]`

Block an IP via Cloudflare WAF IP access rule.

**Arguments**:
- `<ip>`: IPv4 or IPv6 address to block
- `--note <reason>`: Optional note attached to the CF rule. Default: "threat-ops: blocked via CLI"

**Prerequisites**: `CLOUDFLARE_API_TOKEN` and `cloudflare_zone_id` (from terraform.tfvars) must be available.

**Output**: Prints confirmation with Cloudflare rule ID.

**Exit codes**:
- `0`: IP blocked successfully
- `1`: API error or invalid IP
- `2`: IP already blocked

---

### `appserver.sh threats unblock <ip>`

Remove a Cloudflare WAF IP access rule.

**Arguments**:
- `<ip>`: IP address to unblock

**Output**: Prints confirmation.

**Exit codes**:
- `0`: IP unblocked successfully
- `1`: API error or IP not found in blocklist

---

### `appserver.sh threats blocked`

List all IPs currently blocked via Cloudflare WAF IP access rules.

**Output**: Table of IP, note, created date, rule ID.

**Exit codes**:
- `0`: List displayed

## Environment Requirements

- `AWS_PROFILE=appserver` (for SSM access to instance)
- `CLOUDFLARE_API_TOKEN` environment variable (for WAF API calls)
- `cloudflare_zone_id` read from `terraform/terraform.tfvars`
- `jq` installed locally
