# shellcheck shell=bash
# scripts/lib/cloudflare.sh — Cloudflare API + IP-range drift helpers.
# Sourced by appserver.sh. Relies on $TERRAFORM_DIR, $CONFIG_DIR, and die()
# from the parent shell.

# --- Cloudflare API helper ---

get_zone_id() {
  if [[ -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    local z
    z=$(sed -n 's/^cloudflare_zone_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) && [[ -n "$z" ]] && {
      echo "$z"
      return
    }
  fi
  die "Could not read cloudflare_zone_id from terraform.tfvars"
}

# Make authenticated Cloudflare API v4 requests.
# Usage: cf_api <method> <endpoint> [json_body]
# Returns JSON response. Dies on missing credentials.
cf_api() {
  local method="$1" endpoint="$2" body="${3:-}"
  local token="${CLOUDFLARE_API_TOKEN:-}"
  [[ -n "$token" ]] || die "CLOUDFLARE_API_TOKEN not set"

  local zone_id
  zone_id="$(get_zone_id)"

  local url="https://api.cloudflare.com/client/v4/zones/${zone_id}${endpoint}"
  local args=(
    -s -X "$method"
    -H "Authorization: Bearer $token"
    -H "Content-Type: application/json"
    "$url"
  )
  [[ -n "$body" ]] && args+=(-d "$body")

  local response
  response=$(curl "${args[@]}") || die "Cloudflare API request failed"
  echo "$response"
}

# --- Cloudflare IP-range drift detection (for traefik.yml) ---

# Returns 0 if traefik.yml's trustedIPs match live Cloudflare ranges,
# 1 if drifted, 2 on error. Sets globals CF_IP_MISSING / CF_IP_EXTRA / CF_IP_LIVE.
check_cloudflare_ip_drift() {
  local traefik_yml="$CONFIG_DIR/traefik/traefik.yml"
  [ -f "$traefik_yml" ] || return 2

  local live_v4 live_v6 live configured
  live_v4=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v4" 2>/dev/null) || return 2
  live_v6=$(curl -sf --max-time 10 "https://www.cloudflare.com/ips-v6" 2>/dev/null) || return 2
  live=$(printf '%s\n%s' "$live_v4" "$live_v6" | grep -v '^$' | sort)

  configured=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+|[0-9a-f:]+/[0-9]+' "$traefik_yml" \
      | grep -v '^127\.' | grep -v '^172\.16\.' | sort)

  CF_IP_MISSING=$(comm -23 <(echo "$live") <(echo "$configured"))
  CF_IP_EXTRA=$(comm -13 <(echo "$live") <(echo "$configured"))
  CF_IP_LIVE="$live"

  if [ -z "$CF_IP_MISSING" ] && [ -z "$CF_IP_EXTRA" ]; then
    return 0
  fi
  return 1
}

# Rewrite the trustedIPs block in traefik.yml with current Cloudflare ranges.
sync_cloudflare_ips() {
  local traefik_yml="$CONFIG_DIR/traefik/traefik.yml"
  local indent="        "
  local new_block=""
  new_block+="${indent}# Local: cloudflared systemd service connects via localhost/Docker bridge\n"
  new_block+="${indent}- \"127.0.0.0/8\"\n"
  new_block+="${indent}- \"172.16.0.0/12\"\n"
  new_block+="${indent}# Cloudflare public IP ranges (synced $(date +%Y-%m-%d))\n"
  new_block+="${indent}# https://www.cloudflare.com/ips-v4 / ips-v6\n"
  new_block+="${indent}# Audit: ./scripts/appserver.sh config check-ips\n"
  while IFS= read -r cidr; do
    [ -n "$cidr" ] && new_block+="${indent}- \"$cidr\"\n"
  done <<< "$CF_IP_LIVE"

  awk -v new_ips="$new_block" '
    /trustedIPs:/ { print; in_block=1; next }
    in_block && /^[[:space:]]*-/ { next }
    in_block && !/^[[:space:]]*-/ && !/^[[:space:]]*#/ { printf "%s", new_ips; in_block=0 }
    in_block && /^[[:space:]]*#/ { next }
    !in_block { print }
    END { if (in_block) printf "%s", new_ips }
  ' "$traefik_yml" > "${traefik_yml}.tmp" && mv "${traefik_yml}.tmp" "$traefik_yml"
}

cmd_config_check_ips() {
  echo "Checking Cloudflare IP ranges against traefik.yml..."
  check_cloudflare_ip_drift
  local rc=$?

  if [ "$rc" -eq 2 ]; then
    die "Could not fetch Cloudflare IP ranges (network error or traefik.yml missing)"
  fi

  if [ "$rc" -eq 0 ]; then
    echo "Cloudflare IP ranges are up to date."
    return 0
  fi

  # Drift detected — explain the impact
  if [ -n "$CF_IP_MISSING" ]; then
    echo "WARNING: New Cloudflare ranges missing from traefik.yml"
    echo "  Impact: Traefik strips X-Forwarded-For from these edge nodes."
    echo "  Result: Django sees wrong client IP — rate limiting and logging break silently."
    echo "$CF_IP_MISSING" | while read -r cidr; do echo "  + $cidr"; done
  fi
  if [ -n "$CF_IP_EXTRA" ]; then
    echo "Stale ranges (removed by Cloudflare):"
    echo "$CF_IP_EXTRA" | while read -r cidr; do echo "  - $cidr"; done
  fi

  if [ "${1:-}" = "--fix" ]; then
    echo ""
    sync_cloudflare_ips
    echo "Updated traefik.yml. Run 'appserver config push' to deploy."
  else
    echo ""
    echo "Fix with: ./scripts/appserver.sh config check-ips --fix"
  fi
}
