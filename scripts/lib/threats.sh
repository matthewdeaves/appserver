# shellcheck shell=bash
# scripts/lib/threats.sh — access-log analysis + Cloudflare WAF block/allow
# subsystem (cmd_threats_*). About 860 lines extracted from appserver.sh.
#
# Sourced by appserver.sh. Relies on die(), get_region(), get_state_bucket(),
# get_artifacts_bucket(), ssm_run() (from ssm.sh), cf_api() (from cloudflare.sh)
# from the parent shell.

# --- Threat Analysis ---

REPORTS_DIR="$SCRIPT_DIR/../reports/threats"

# Collect app-layer security data from the instance via SSM.
# Gathers: cookie_admin audit events, nginx 4xx/5xx summary, container die/OOM
# events, and cloudflared warning lines — all within the given time window.
# Outputs a JSON object ready to be merged into the threat report.
_collect_app_security() {
  local duration_sec="$1"
  local app_script
  app_script=$(cat <<'APP_EOF'
set -e
CUTOFF_ISO=$(date -u -d "$DURATION_SEC seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u -v-"${DURATION_SEC}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
          || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Cookie security audit (last 200 events)
AUDIT='{"ok":false,"events":[]}'
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  AUDIT=$(docker exec cookie-web python manage.py cookie_admin audit --json --lines 200 2>/dev/null \
          || echo '{"ok":false,"events":[]}')
fi

# Nginx status code summary from cookie-web (last 2000 access log lines)
NGINX_5XX=0
NGINX_4XX=0
TOP_ERROR_PATHS=""
if docker ps --filter name=cookie-web --filter status=running --format '{{.Names}}' 2>/dev/null | grep -q cookie-web; then
  NGINX_LINES=$(docker exec cookie-web tail -2000 /var/log/nginx/access.log 2>/dev/null || echo "")
  if [[ -n "$NGINX_LINES" ]]; then
    NGINX_5XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^5[0-9]{2}$' || echo 0)
    NGINX_4XX=$(echo "$NGINX_LINES" | awk '{print $9}' | grep -cE '^4[0-9]{2}$' || echo 0)
    TOP_ERROR_PATHS=$(echo "$NGINX_LINES" \
      | awk '$9 ~ /^[45][0-9]{2}$/ {print $7}' \
      | sort | uniq -c | sort -rn | head -10 \
      | awk '{printf "%s:%s,", $2, $1}' | sed 's/,$//' || echo "")
  fi
fi

# Docker container die/OOM events since cutoff.
# --until is required: without it docker events tails live events indefinitely,
# causing the subshell to hang when no historical events exist.
UNTIL_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONTAINER_RESTARTS=$(docker events --since "$CUTOFF_ISO" --until "$UNTIL_ISO" \
  --filter type=container \
  --filter event=die \
  --filter event=oom \
  --format '{{.Time}} {{.Actor.Attributes.name}} {{.Action}} exit={{.Actor.Attributes.exitCode}}' \
  2>/dev/null | head -20 || echo "")

# cloudflared warnings since cutoff
TUNNEL_WARNINGS=$(journalctl -u cloudflared --since "$CUTOFF_ISO" \
  --no-pager -o short 2>/dev/null \
  | grep -iE "error|warn|failed|disconnect|reconn|retry" \
  | tail -10 || echo "")

# Emit structured JSON
jq -n \
  --arg audit_raw "$AUDIT" \
  --arg nginx_5xx "$NGINX_5XX" \
  --arg nginx_4xx "$NGINX_4XX" \
  --arg top_error_paths "$TOP_ERROR_PATHS" \
  --arg container_restarts "$CONTAINER_RESTARTS" \
  --arg tunnel_warnings "$TUNNEL_WARNINGS" \
  '{
    app_security: (
      ($audit_raw | fromjson? // {"ok":false,"events":[]}) |
      {
        audit_ok: (.ok // false),
        event_count: (.events // [] | length),
        recent_registrations: (.events // [] | map(select(.type == "registration")) | length),
        recent_logins: (.events // [] | map(select(.type == "passkey_login" or .type == "device_code_authorized")) | length),
        events_sample: (.events // [] | .[0:5])
      }
    ),
    app_errors: {
      nginx_5xx: ($nginx_5xx | tonumber? // 0),
      nginx_4xx: ($nginx_4xx | tonumber? // 0),
      top_error_paths: (
        if $top_error_paths == "" then []
        else ($top_error_paths | split(",") | map(select(length > 0))
          | map(split(":") | {path: .[0], count: (.[1] | tonumber? // 0)}))
        end
      )
    },
    container_events: {
      restarts: (if $container_restarts == ""
        then []
        else ($container_restarts | split("\n") | map(select(length > 0)))
        end)
    },
    tunnel_health: {
      warnings: (if $tunnel_warnings == ""
        then []
        else ($tunnel_warnings | split("\n") | map(select(length > 0)))
        end)
    }
  }'
APP_EOF
)
  app_script="DURATION_SEC=$duration_sec
$app_script"
  ssm_run "$app_script" 60 2>/dev/null || echo '{}'
}

# Compare yesterday's AWS spend against the day before to detect cost anomalies.
# Uses the Cost Explorer API (us-east-1 always). Returns JSON with anomaly field:
# "normal" | "elevated" (>$2/day) | "spike" (>1.5x previous day).
_check_cost_anomaly() {
  local today yesterday two_days_ago
  today=$(date +%Y-%m-%d)
  yesterday=$(date -d '1 day ago' +%Y-%m-%d 2>/dev/null \
           || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
  two_days_ago=$(date -d '2 days ago' +%Y-%m-%d 2>/dev/null \
              || date -v-2d +%Y-%m-%d 2>/dev/null || echo "")
  [[ -n "$yesterday" && -n "$two_days_ago" ]] \
    || { echo '{"available":false,"reason":"date calculation failed"}'; return; }

  local result
  result=$(aws ce get-cost-and-usage \
    --profile appserver \
    --time-period "Start=${two_days_ago},End=${today}" \
    --granularity DAILY \
    --metrics BlendedCost \
    --region us-east-1 \
    --output json 2>/dev/null) \
    || { echo '{"available":false,"reason":"API call failed"}'; return; }

  echo "$result" | jq '
    .ResultsByTime as $r |
    if ($r | length) >= 2 then
      (($r[-2].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $prev |
      (($r[-1].Total.BlendedCost.Amount | tonumber) * 100 | round / 100 | fabs) as $curr |
      {
        available: true,
        yesterday: $curr,
        day_before: $prev,
        currency: $r[-1].Total.BlendedCost.Unit,
        anomaly: (
          if $prev > 0.01 and $curr > ($prev * 1.5) then "spike"
          elif $curr > 2.0 then "elevated"
          else "normal"
          end
        )
      }
    else {"available":false,"reason":"insufficient data"}
    end
  ' 2>/dev/null || echo '{"available":false,"reason":"parse failed"}'
}

cmd_threats_analyze() {
  local since="24h"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="${2:?--since requires a value}"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  # Validate --since format
  [[ "$since" =~ ^[0-9]+(h|d)$ ]] || die "Invalid --since format: $since (use e.g. 1h, 6h, 24h, 7d)"

  echo "Analyzing access logs (last $since)..."

  # Convert duration to seconds for jq time filtering
  local duration_sec
  local num="${since%[hd]}"
  local unit="${since: -1}"
  case "$unit" in
    h) duration_sec=$((num * 3600)) ;;
    d) duration_sec=$((num * 86400)) ;;
  esac

  # Build the on-instance analysis script
  local analysis_script
  analysis_script=$(cat <<'ANALYSIS_EOF'
set -e

ACCESS_LOG="/var/log/traefik/access.log"
if [[ ! -f "$ACCESS_LOG" ]] || [[ ! -s "$ACCESS_LOG" ]]; then
  echo '{"error":"No access log found or log is empty"}' >&2
  exit 1
fi

CUTOFF_EPOCH=$(($(date +%s) - DURATION_SEC))

# Scanner path patterns (one per line for grep -f)
SCANNER_PATHS=$(cat <<'PATHS'
wp-admin
wp-login
wp-content
wp-includes
xmlrpc.php
\.env
\.git
\.svn
\.htaccess
\.htpasswd
\.DS_Store
config\.yml
config\.json
composer\.json
package\.json
Dockerfile
phpmyadmin
adminer
/admin
cpanel
webmail
/shell
/cmd
/console
/terminal
cgi-bin
/solr
/actuator
/api/v1/pods
\.well-known/openid
/debug
/trace
/server-status
/server-info
/manager/html
/jenkins
/swagger
phpinfo
/telescope
PATHS
)

# Scanner user agent patterns
SCANNER_UAS="sqlmap|nikto|nmap|masscan|zgrab|nuclei|dirbuster|gobuster|ffuf|wfuzz|hydra|medusa|w3af|skipfish|arachni|acunetix|nessus|openvas|burpsuite"

# Main analysis with jq — filter by time window, aggregate per IP
jq -s --argjson cutoff "$CUTOFF_EPOCH" '
  # Parse entries and filter by time window
  [ .[] | select(
    (.StartUTC // "" | length > 0) and
    ((.StartUTC | split(".")[0] + "Z" | fromdateiso8601) >= $cutoff)
  ) ] |

  # Aggregate stats
  {
    log_entries_analyzed: length,
    unique_ips: ([.[].request_CF_Connecting_IP // .[].ClientHost] | unique | length),
    total_requests: length,
    per_ip: (
      group_by(.request_CF_Connecting_IP // .ClientHost) |
      map({
        ip: (.[0].request_CF_Connecting_IP // .[0].ClientHost),
        count: length,
        paths: [.[].RequestPath] | unique | .[0:10],
        user_agents: [.[].request_User_Agent // ""] | unique | .[0:5],
        status_codes: (group_by(.DownstreamStatus) | map({(.[0].DownstreamStatus | tostring): length}) | add),
        first_seen: ([.[].StartUTC] | sort | first),
        last_seen: ([.[].StartUTC] | sort | last),
        methods: ([.[].RequestMethod] | unique)
      }) |
      sort_by(-.count)
    )
  }
' "$ACCESS_LOG" 2>/dev/null || echo '{"error":"jq analysis failed"}'
ANALYSIS_EOF
)

  # Inject the duration variable
  analysis_script="DURATION_SEC=$duration_sec
$analysis_script"

  local raw_output
  raw_output=$(ssm_run "$analysis_script" 120) || {
    echo "ERROR: Failed to run analysis on instance" >&2
    return 2
  }

  # Check for error
  local error
  error=$(echo "$raw_output" | jq -r '.error // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    echo "ERROR: $error" >&2
    return 2
  fi

  # Generate findings and recommendations locally
  local timestamp
  timestamp=$(date -u +"%Y%m%d-%H%M%S")
  local report_dir="$REPORTS_DIR/$timestamp"
  mkdir -p "$report_dir"

  # Process raw data into findings + recommendations
  local report
  report=$(echo "$raw_output" | jq --arg since "$since" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
    # Scanner path patterns
    def is_scanner_path:
      test("wp-admin|wp-login|wp-content|wp-includes|xmlrpc|\\.(env|git|svn|htaccess|htpasswd|DS_Store)|config\\.(yml|json)|composer\\.json|package\\.json|Dockerfile|phpmyadmin|adminer|/admin|cpanel|webmail|/shell|/cmd|/console|/terminal|cgi-bin|/solr|/actuator|/api/v1/pods|/debug|/trace|/server-status|/server-info|/manager/html|/jenkins|/swagger|phpinfo|/telescope"; "i");

    # Scanner user agent patterns
    def is_scanner_ua:
      test("sqlmap|nikto|nmap|masscan|zgrab|nuclei|dirbuster|gobuster|ffuf|wfuzz|hydra|medusa|w3af|skipfish|arachni|acunetix|nessus|openvas|burpsuite"; "i");

    # Traversal patterns
    def is_traversal:
      test("\\.\\.(/|%2[fF]|%252[fF])");

    # Determine categories for each IP
    .per_ip | map(
      . as $ip |
      {
        ip: .ip,
        count: .count,
        paths: .paths,
        user_agents: .user_agents,
        status_codes: .status_codes,
        first_seen: .first_seen,
        last_seen: .last_seen,
        categories: (
          [
            (if ([.paths[] | select(is_scanner_path)] | length) > 0 then "path_scan" else empty end),
            (if ([.user_agents[] | select(is_scanner_ua)] | length) > 0 then "scanner_ua" else empty end),
            (if ([.paths[] | select(is_traversal)] | length) > 0 then "traversal" else empty end),
            (if .count > 100 then "high_rate" else empty end),
            (if ((.status_codes // {}) | to_entries | map(select(.key | test("^(401|403)$"))) | map(.value) | add // 0) > 10
              and ([.paths[] | select(test("/api/auth|/login|/signin|/session"; "i"))] | length) > 0
              then "auth_brute_force" else empty end)
          ]
        ),
        error_ratio: (
          ((.status_codes // {}) | to_entries |
            { errors: (map(select(.key | test("^[45]"))) | map(.value) | add // 0),
              total: (map(.value) | add // 1) }) |
          (.errors / .total)
        )
      }
    ) |

    # Filter to only IPs with threat signals
    map(select(.categories | length > 0 or .error_ratio > 0.9)) |

    # Generate findings
    . as $threats |
    {
      timestamp: $ts,
      time_window: $since,
      log_entries_analyzed: (input.log_entries_analyzed // 0),
      unique_ips: (input.unique_ips // 0),
      total_requests: (input.total_requests // 0),
      status: (if ($threats | length) > 0 then "threats_detected" else "clean" end),
      findings: [
        $threats | to_entries[] |
        .value as $t | .key as $idx |
        {
          id: ("F-" + (($idx + 1) | tostring | if length < 3 then "0" * (3 - length) + . else . end)),
          category: ($t.categories[0] // "suspicious"),
          severity: (
            if ($t.categories | any(. == "traversal")) and ($t.error_ratio < 0.95) then "critical"
            elif ($t.categories | any(. == "auth_brute_force")) then "high"
            elif $t.count > 500 or ($t.categories | length) > 1 then "high"
            elif $t.count > 50 then "medium"
            elif $t.count > 10 then "low"
            else "info"
            end
          ),
          ip: $t.ip,
          count: $t.count,
          sample_paths: $t.paths[0:5],
          sample_ua: ($t.user_agents[0] // ""),
          first_seen: $t.first_seen,
          last_seen: $t.last_seen,
          status_codes: ($t.status_codes // {})
        }
      ] | sort_by(
        if .severity == "critical" then 0
        elif .severity == "high" then 1
        elif .severity == "medium" then 2
        elif .severity == "low" then 3
        else 4 end
      ),
      recommendations: [],
      cf_edge: null
    }
  ' - <<<"$raw_output" 2>/dev/null)

  # If jq processing failed, try a simpler approach
  if [[ -z "$report" ]] || [[ "$report" == "null" ]]; then
    report=$(echo "$raw_output" | jq --arg since "$since" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
      {
        timestamp: $ts,
        time_window: $since,
        log_entries_analyzed: .log_entries_analyzed,
        unique_ips: .unique_ips,
        total_requests: .total_requests,
        status: "clean",
        findings: [],
        recommendations: [],
        cf_edge: null
      }
    ')
  fi

  # Generate recommendations from findings
  report=$(echo "$report" | jq '
    .recommendations = [
      .findings[] |
      select(.severity == "critical" or .severity == "high" or
        (.severity == "medium" and .count > 100)) |
      {
        id: (.id | sub("^F-"; "R-")),
        action: (
          if .category == "traversal" then "block_ip"
          elif .category == "auth_brute_force" then "block_ip"
          elif .category == "scanner_ua" then "block_ip"
          elif .category == "path_scan" and .count > 100 then "block_ip"
          elif .category == "high_rate" then "monitor"
          else "investigate"
          end
        ),
        target: .ip,
        rationale: (
          "\(.category): \(.count) requests, " +
          (if (.status_codes | to_entries | map(select(.key | test("^[45]"))) | map(.value) | add // 0) as $errs |
              (.count) as $total |
              (($errs / (if $total == 0 then 1 else $total end)) * 100 | floor)
            then "\(.)% error responses"
            else "unknown error ratio"
          end) +
          ", \(.sample_ua)" +
          " (\(.id))"
        ),
        confidence: (
          if .severity == "critical" or .severity == "high" then "high"
          elif .severity == "medium" then "medium"
          else "low"
          end
        ),
        finding_ids: [.id]
      }
    ]
  ')

  # Attempt CF edge data enrichment (optional — requires Analytics:Read permission)
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    local cf_edge_response
    local zone_id
    zone_id="$(get_zone_id 2>/dev/null)" || zone_id=""
    if [[ -n "$zone_id" ]]; then
      local since_ts
      since_ts=$(date -u -d "$duration_sec seconds ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${duration_sec}S" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      local until_ts
      until_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      if [[ -n "$since_ts" ]]; then
        local gql_query
        gql_query=$(jq -n --arg zone "$zone_id" --arg since "$since_ts" --arg until "$until_ts" '{
          query: "query { viewer { zones(filter: {zoneTag: $zoneTag}) { firewallEventsAdaptive(filter: {datetime_gt: $since, datetime_lt: $until}, limit: 100, orderBy: [datetime_DESC]) { action clientIP datetime ruleId source } } } }",
          variables: { zoneTag: $zone, since: $since, until: $until }
        }')

        cf_edge_response=$(curl -s -X POST \
          "https://api.cloudflare.com/client/v4/graphql" \
          -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
          -H "Content-Type: application/json" \
          -d "$gql_query" 2>/dev/null) || cf_edge_response=""

        # Check if we got a valid response (not 403)
        local cf_errors
        cf_errors=$(echo "$cf_edge_response" | jq -r '.errors[]?.message // empty' 2>/dev/null)
        if [[ -z "$cf_errors" ]] && echo "$cf_edge_response" | jq -e '.data.viewer.zones[0]' &>/dev/null; then
          local cf_edge
          cf_edge=$(echo "$cf_edge_response" | jq '{
            available: true,
            waf_blocks: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.action == "block")] | length),
            rate_limit_triggers: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.source == "rateLimit")] | length),
            top_blocked_ips: ([.data.viewer.zones[0].firewallEventsAdaptive[]? | select(.action == "block") | .clientIP] | group_by(.) | map({ip: .[0], count: length}) | sort_by(-.count) | .[0:5])
          }')
          report=$(echo "$report" | jq --argjson edge "$cf_edge" '.cf_edge = $edge')
        fi
      fi
    fi
  fi

  # Collect app security data (cookie audit + nginx + containers + tunnel)
  echo "Collecting app security data..."
  local app_data
  app_data=$(_collect_app_security "$duration_sec")
  if echo "$app_data" | jq -e '.app_security' &>/dev/null; then
    report=$(echo "$report" | jq --argjson app "$app_data" '. + $app')
  fi

  # Cost anomaly check (local AWS CE call)
  echo "Checking AWS cost..."
  local cost_data
  cost_data=$(_check_cost_anomaly)
  report=$(echo "$report" | jq --argjson cost "$cost_data" '.cost_anomaly = $cost')

  # Write report.json
  echo "$report" | jq '.' > "$report_dir/report.json"

  # Generate SUMMARY.md
  local finding_count rec_count report_status total_requests unique_ips
  finding_count=$(echo "$report" | jq '.findings | length')
  rec_count=$(echo "$report" | jq '.recommendations | length')
  report_status=$(echo "$report" | jq -r '.status')
  total_requests=$(echo "$report" | jq '.total_requests')
  unique_ips=$(echo "$report" | jq '.unique_ips')

  {
    echo "# Threat Report: $(date -u +"%Y-%m-%d %H:%M")"
    echo
    echo "**Window**: Last $since | **Requests**: $total_requests | **Unique IPs**: $unique_ips | **Status**: $(echo "$report_status" | tr '_' ' ' | tr '[:lower:]' '[:upper:]')"
    echo

    if [[ "$finding_count" -gt 0 ]]; then
      echo "## Findings ($finding_count threats)"
      echo
      echo "$report" | jq -r '.findings[] |
        "### [\(.severity | ascii_upcase)] \(.id): \(.category | gsub("_"; " ")) from \(.ip)\n" +
        "- **Requests**: \(.count) (" + (.status_codes | to_entries | map("\(.key): \(.value)") | join(", ")) + ")\n" +
        "- **Paths**: " + (.sample_paths | join(", ")) + "\n" +
        "- **User Agent**: \(.sample_ua)\n" +
        "- **Window**: \(.first_seen // "?") — \(.last_seen // "?")\n"'
    else
      echo "## Findings"
      echo
      echo "_No threats detected._"
    fi

    echo
    echo "## Recommendations"
    echo

    if [[ "$rec_count" -gt 0 ]]; then
      echo "| ID | Action | Target | Confidence | Rationale |"
      echo "|----|--------|--------|------------|-----------|"
      echo "$report" | jq -r '.recommendations[] | "| \(.id) | \(.action) | \(.target) | \(.confidence) | \(.rationale) |"'
    else
      echo "_No recommendations._"
    fi

    # CF Edge section if data available
    local cf_available
    cf_available=$(echo "$report" | jq -r '.cf_edge.available // false')
    if [[ "$cf_available" == "true" ]]; then
      echo
      echo "## Cloudflare Edge"
      echo
      echo "_Traffic blocked before reaching the server:_"
      echo
      echo "- **WAF Blocks**: $(echo "$report" | jq '.cf_edge.waf_blocks')"
      echo "- **Rate Limit Triggers**: $(echo "$report" | jq '.cf_edge.rate_limit_triggers')"
      local top_blocked
      top_blocked=$(echo "$report" | jq -r '.cf_edge.top_blocked_ips[]? | "- \(.ip) (\(.count) blocks)"')
      if [[ -n "$top_blocked" ]]; then
        echo
        echo "**Top Blocked IPs:**"
        echo "$top_blocked"
      fi
    fi

    # App Security section
    local app_audit_ok registrations logins nginx_5xx nginx_4xx container_count tunnel_count
    app_audit_ok=$(echo "$report" | jq -r '.app_security.audit_ok // false')
    registrations=$(echo "$report" | jq -r '.app_security.recent_registrations // "?"')
    logins=$(echo "$report" | jq -r '.app_security.recent_logins // "?"')
    nginx_5xx=$(echo "$report" | jq -r '.app_errors.nginx_5xx // 0')
    nginx_4xx=$(echo "$report" | jq -r '.app_errors.nginx_4xx // 0')
    container_count=$(echo "$report" | jq '.container_events.restarts | length // 0')
    tunnel_count=$(echo "$report" | jq '.tunnel_health.warnings | length // 0')

    if [[ "$app_audit_ok" == "true" ]] || [[ "$nginx_5xx" -gt 0 ]] || [[ "$nginx_4xx" -gt 0 ]]; then
      echo
      echo "## App Security"
      echo
      echo "- **Registrations (window)**: $registrations"
      echo "- **Auth events (window)**: $logins"
      echo "- **App 5xx errors** (last 2000 nginx lines): $nginx_5xx"
      echo "- **App 4xx errors** (last 2000 nginx lines): $nginx_4xx"
      if [[ "$nginx_5xx" -gt 10 ]]; then
        echo
        echo "⚠️ **Elevated 5xx count** — check Cookie logs"
        echo
        echo "$report" | jq -r '.app_errors.top_error_paths[]? | "  \(.path) (\(.count))"' | head -5
      fi
    fi

    if [[ "$container_count" -gt 0 ]]; then
      echo
      echo "## Container Events"
      echo
      echo "$report" | jq -r '.container_events.restarts[]?' | head -10
    fi

    if [[ "$tunnel_count" -gt 0 ]]; then
      echo
      echo "## Tunnel Warnings"
      echo
      echo "$report" | jq -r '.tunnel_health.warnings[]?' | head -5
    fi

    # Cost check section
    local cost_available cost_anomaly cost_yesterday cost_day_before cost_currency
    cost_available=$(echo "$report" | jq -r '.cost_anomaly.available // false')
    cost_anomaly=$(echo "$report" | jq -r '.cost_anomaly.anomaly // "unknown"')
    if [[ "$cost_available" == "true" ]]; then
      cost_yesterday=$(echo "$report" | jq -r '.cost_anomaly.yesterday')
      cost_day_before=$(echo "$report" | jq -r '.cost_anomaly.day_before')
      cost_currency=$(echo "$report" | jq -r '.cost_anomaly.currency')
      echo
      echo "## Cost Check"
      echo
      echo "- **Yesterday**: ${cost_yesterday} ${cost_currency}"
      echo "- **Day before**: ${cost_day_before} ${cost_currency}"
      echo "- **Status**: ${cost_anomaly}"
      if [[ "$cost_anomaly" == "spike" ]]; then
        echo
        echo "⚠️ **Cost spike detected** — investigate for unauthorized resource usage"
      fi
    fi

    echo
    echo "## Actions Taken"
    echo
    echo "_No actions taken yet. Use \`appserver.sh threats block <ip>\` or the threat-ops skill to enact recommendations._"
  } > "$report_dir/SUMMARY.md"

  # Initialize empty actions.json
  echo "[]" > "$report_dir/actions.json"

  # Print summary to stdout
  echo
  cat "$report_dir/SUMMARY.md"
  echo
  echo "Report saved to: $report_dir/"

  # Exit code based on status
  if [[ "$report_status" == "threats_detected" ]]; then
    return 1
  fi
  return 0
}

cmd_threats_block() {
  local ip="" note="threat-ops: blocked via CLI"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:?--note requires a value}"; shift 2 ;;
      -*) die "Unknown flag: $1" ;;
      *) ip="$1"; shift ;;
    esac
  done

  [[ -n "$ip" ]] || die "Usage: appserver threats block <ip> [--note <reason>]"

  # Validate IP format (IPv4 or IPv6)
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    die "Invalid IP format: $ip"
  fi

  echo "Blocking $ip..."
  local body
  body=$(jq -n --arg ip "$ip" --arg note "$note" '{
    mode: "block",
    configuration: { target: "ip", value: $ip },
    notes: $note
  }')

  local response
  response=$(cf_api POST "/firewall/access_rules/rules" "$body")

  local success
  success=$(echo "$response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    # Check if already blocked
    local errors
    errors=$(echo "$response" | jq -r '.errors[]?.message // empty')
    if echo "$errors" | grep -qi "already exists"; then
      echo "IP $ip is already blocked."
      return 2
    fi
    echo "ERROR: Failed to block $ip" >&2
    echo "$response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result.id')
  echo "Blocked $ip (rule ID: $rule_id)"

  # Track action in latest report's actions.json
  _track_action "block_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_unblock() {
  local ip="${1:?Usage: appserver threats unblock <ip>}"

  echo "Looking up block rule for $ip..."
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=block&configuration.value=$ip")

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result[]? | select(.configuration.value == "'"$ip"'") | .id' | head -1)

  if [[ -z "$rule_id" ]]; then
    echo "ERROR: No block rule found for $ip" >&2
    return 1
  fi

  local del_response
  del_response=$(cf_api DELETE "/firewall/access_rules/rules/$rule_id")

  local success
  success=$(echo "$del_response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    echo "ERROR: Failed to unblock $ip" >&2
    echo "$del_response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  echo "Unblocked $ip (removed rule $rule_id)"
  _track_action "unblock_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_blocked() {
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=block&per_page=50")

  local count
  count=$(echo "$response" | jq '.result | length')

  if [[ "$count" -eq 0 ]]; then
    echo "No IPs currently blocked."
    return 0
  fi

  echo "Blocked IPs ($count):"
  echo
  printf "%-18s %-40s %-22s %s\n" "IP" "Note" "Created" "Rule ID"
  printf "%-18s %-40s %-22s %s\n" "--" "----" "-------" "-------"
  echo "$response" | jq -r '.result[] | [.configuration.value, .notes, .created_on, .id] | @tsv' |
    while IFS=$'\t' read -r ip note created rule_id; do
      printf "%-18s %-40s %-22s %s\n" "$ip" "${note:0:38}" "${created:0:19}" "$rule_id"
    done
}

cmd_threats_allow() {
  # Create a Cloudflare IP Access Rule of mode "whitelist" so the caller IP
  # bypasses WAF challenges and rate limits — primarily for pentest sessions.
  # With no IP argument, auto-detects the caller's public IP via ifconfig.me.
  local ip="" note="pentest: allowlist via CLI"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="${2:?--note requires a value}"; shift 2 ;;
      -*) die "Unknown flag: $1" ;;
      *) ip="$1"; shift ;;
    esac
  done

  if [[ -z "$ip" ]]; then
    echo "No IP specified — detecting public IP..."
    ip=$(curl -fsS https://ifconfig.me 2>/dev/null) \
      || die "Failed to detect public IP. Provide it explicitly: appserver threats allow <ip>"
    echo "Detected public IP: $ip"
  fi

  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
    die "Invalid IP format: $ip"
  fi

  echo "Allowlisting $ip..."
  local body
  body=$(jq -n --arg ip "$ip" --arg note "$note" '{
    mode: "whitelist",
    configuration: { target: "ip", value: $ip },
    notes: $note
  }')

  local response
  response=$(cf_api POST "/firewall/access_rules/rules" "$body")

  local success
  success=$(echo "$response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    local errors
    errors=$(echo "$response" | jq -r '.errors[]?.message // empty')
    if echo "$errors" | grep -qi "already exists"; then
      echo "IP $ip is already allowlisted."
      return 2
    fi
    echo "ERROR: Failed to allowlist $ip" >&2
    echo "$response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result.id')
  echo "Allowlisted $ip (rule ID: $rule_id)"
  echo "Reminder: run 'appserver threats unallow $ip' once the pentest scan completes."

  _track_action "allow_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_unallow() {
  local ip="${1:?Usage: appserver threats unallow <ip>}"

  echo "Looking up allow rule for $ip..."
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=whitelist&configuration.value=$ip")

  local rule_id
  rule_id=$(echo "$response" | jq -r '.result[]? | select(.configuration.value == "'"$ip"'") | .id' | head -1)

  if [[ -z "$rule_id" ]]; then
    echo "ERROR: No allow rule found for $ip" >&2
    return 1
  fi

  local del_response
  del_response=$(cf_api DELETE "/firewall/access_rules/rules/$rule_id")

  local success
  success=$(echo "$del_response" | jq -r '.success')
  if [[ "$success" != "true" ]]; then
    echo "ERROR: Failed to remove allow rule for $ip" >&2
    echo "$del_response" | jq -r '.errors[]?.message // empty' >&2
    return 1
  fi

  echo "Removed allow rule for $ip (removed rule $rule_id)"
  _track_action "unallow_ip" "$ip" "$rule_id" "success" ""
}

cmd_threats_allowed() {
  local response
  response=$(cf_api GET "/firewall/access_rules/rules?mode=whitelist&per_page=50")

  local count
  count=$(echo "$response" | jq '.result | length')

  if [[ "$count" -eq 0 ]]; then
    echo "No IPs currently allowlisted."
    return 0
  fi

  echo "Allowlisted IPs ($count):"
  echo
  printf "%-18s %-40s %-22s %s\n" "IP" "Note" "Created" "Rule ID"
  printf "%-18s %-40s %-22s %s\n" "--" "----" "-------" "-------"
  echo "$response" | jq -r '.result[] | [.configuration.value, .notes, .created_on, .id] | @tsv' |
    while IFS=$'\t' read -r ip note created rule_id; do
      printf "%-18s %-40s %-22s %s\n" "$ip" "${note:0:38}" "${created:0:19}" "$rule_id"
    done
}

cmd_threats_list() {
  if [[ ! -d "$REPORTS_DIR" ]]; then
    echo "No threat reports found."
    return 0
  fi

  local dirs
  dirs=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)

  if [[ -z "$dirs" ]]; then
    echo "No threat reports found."
    return 0
  fi

  echo "Threat Reports:"
  echo
  printf "%-20s %-20s %-10s %s\n" "Timestamp" "Status" "Findings" "Recommendations"
  printf "%-20s %-20s %-10s %s\n" "---------" "------" "--------" "---------------"

  while IFS= read -r dir; do
    local ts
    ts=$(basename "$dir")
    if [[ -f "$dir/report.json" ]]; then
      local status finding_count rec_count
      status=$(jq -r '.status // "unknown"' "$dir/report.json")
      finding_count=$(jq '.findings | length' "$dir/report.json")
      rec_count=$(jq '.recommendations | length' "$dir/report.json")
      printf "%-20s %-20s %-10s %s\n" "$ts" "$status" "$finding_count" "$rec_count"
    else
      printf "%-20s %-20s %-10s %s\n" "$ts" "(no report.json)" "-" "-"
    fi
  done <<< "$dirs"
}

cmd_threats_report() {
  local ts="${1:-}"

  if [[ -z "$ts" ]]; then
    # Find latest
    if [[ ! -d "$REPORTS_DIR" ]]; then
      echo "No threat reports found."
      return 1
    fi
    local latest
    latest=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
    if [[ -z "$latest" ]]; then
      echo "No threat reports found."
      return 1
    fi
    ts=$(basename "$latest")
  fi

  local report_dir="$REPORTS_DIR/$ts"
  if [[ ! -d "$report_dir" ]]; then
    echo "Report not found: $ts"
    return 1
  fi

  if [[ -f "$report_dir/SUMMARY.md" ]]; then
    cat "$report_dir/SUMMARY.md"
  else
    echo "No SUMMARY.md in $report_dir"
    return 1
  fi

  # Show actions if any
  if [[ -f "$report_dir/actions.json" ]]; then
    local action_count
    action_count=$(jq 'length' "$report_dir/actions.json")
    if [[ "$action_count" -gt 0 ]]; then
      echo
      echo "## Actions Log ($action_count)"
      echo
      jq -r '.[] | "- [\(.timestamp)] \(.action_type) \(.target) → \(.result)"' "$report_dir/actions.json"
    fi
  fi
}

# Track a block/unblock action in the latest report's actions.json
_track_action() {
  local action_type="$1" target="$2" cf_rule_id="$3" result="$4" error="$5"

  # Find latest report dir
  local latest_dir=""
  if [[ -d "$REPORTS_DIR" ]]; then
    latest_dir=$(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
  fi

  if [[ -z "$latest_dir" ]]; then
    return 0  # No report to track against
  fi

  local actions_file="$latest_dir/actions.json"
  [[ -f "$actions_file" ]] || echo "[]" > "$actions_file"

  local action
  action=$(jq -n \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg at "$action_type" \
    --arg tgt "$target" \
    --arg rid "$cf_rule_id" \
    --arg res "$result" \
    --arg err "$error" \
    '{
      timestamp: $ts,
      recommendation_id: null,
      action_type: $at,
      target: $tgt,
      cf_rule_id: $rid,
      result: $res,
      error: (if $err == "" then null else $err end)
    }')

  local updated
  updated=$(jq --argjson action "$action" '. += [$action]' "$actions_file")
  echo "$updated" > "$actions_file"
}

cmd_threats() {
  case "${1:-}" in
    report)   shift; cmd_threats_report "$@" ;;
    list)     cmd_threats_list ;;
    block)    shift; cmd_threats_block "$@" ;;
    unblock)  shift; cmd_threats_unblock "$@" ;;
    blocked)  cmd_threats_blocked ;;
    allow)    shift; cmd_threats_allow "$@" ;;
    unallow)  shift; cmd_threats_unallow "$@" ;;
    allowed)  cmd_threats_allowed ;;
    ""|--*)   cmd_threats_analyze "$@" ;;
    *)        echo "Usage: appserver threats [--since <duration>] | report [<timestamp>] | list | block <ip> | unblock <ip> | blocked | allow [<ip>] | unallow <ip> | allowed" ;;
  esac
}
