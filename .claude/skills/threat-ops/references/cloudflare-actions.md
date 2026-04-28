# Cloudflare Actions Reference

## Prerequisites

- `CLOUDFLARE_API_TOKEN` environment variable set
- Token needs: **Zone WAF Edit** (for IP access rules)
- Optional: **Zone Analytics → Read** (for CF edge data enrichment via `firewallEventsAdaptive` GraphQL)
- `cloudflare_zone_id` in `terraform/terraform.tfvars`

## IP Access Rules API

Base URL: `https://api.cloudflare.com/client/v4/zones/{zone_id}/firewall/access_rules/rules`

### Block an IP

```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "mode": "block",
    "configuration": { "target": "ip", "value": "1.2.3.4" },
    "notes": "threat-ops: scanner detected"
  }'
```

**Response**: `{ "success": true, "result": { "id": "abc123...", ... } }`

**Already blocked**: Returns error with message containing "already exists". Exit code 2.

### List Blocked IPs

```bash
curl "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules?mode=block&per_page=50" \
  -H "Authorization: Bearer $CF_TOKEN"
```

**Response**: `{ "result": [{ "id": "...", "configuration": { "value": "1.2.3.4" }, "notes": "...", "created_on": "..." }] }`

### Remove a Block

```bash
# First find the rule ID by listing and filtering by IP
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/access_rules/rules/$RULE_ID" \
  -H "Authorization: Bearer $CF_TOKEN"
```

## CLI Wrappers

The `appserver.sh threats` command wraps all CF API calls:

```bash
./scripts/appserver.sh threats block 1.2.3.4 --note "scanner: zgrab"
./scripts/appserver.sh threats unblock 1.2.3.4
./scripts/appserver.sh threats blocked
```

## Rate Limits

- **API rate limit**: 1200 requests per 5 minutes (per token)
- **IP access rule limit**: 50,000 rules on free plan
- Manual blocking won't approach these limits

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| 403 Forbidden | Token lacks Zone WAF Edit | Update token permissions |
| "already exists" | IP already has a block rule | Not an error — exit 2 |
| 429 Too Many Requests | Rate limit exceeded | Wait and retry (unlikely with manual ops) |
| Network error | DNS/connectivity issue | Check internet connection |

## GraphQL Analytics API (Optional)

Used for CF edge data enrichment. Requires **Analytics:Read** permission.

```bash
curl -X POST "https://api.cloudflare.com/client/v4/graphql" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "query": "query { viewer { zones(filter: {zoneTag: $zoneTag}) { firewallEventsAdaptive(filter: {datetime_gt: $since, datetime_lt: $until}, limit: 100) { action clientIP datetime } } } }",
    "variables": { "zoneTag": "ZONE_ID", "since": "2026-04-05T00:00:00Z", "until": "2026-04-06T00:00:00Z" }
  }'
```

If 403 (missing permission), `cf_edge` is set to `null` in the report — no error raised.
