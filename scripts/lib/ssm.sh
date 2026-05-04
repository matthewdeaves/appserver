# shellcheck shell=bash
# scripts/lib/ssm.sh — SSM SendCommand helper + every subcommand that runs
# shell on the EC2 instance via SSM.
#
# Sourced by appserver.sh. Relies on die(), get_region(), get_instance_id(),
# get_artifacts_bucket(), package_and_upload_artifact(),
# check_cloudflare_ip_drift() (from cloudflare.sh) from the parent shell.

# Run a command on the instance via SSM and return stdout.
# Usage: ssm_run <command_string> [timeout_seconds]
ssm_run() {
  local cmd_string="$1"
  local timeout="${2:-30}"
  local instance_id region cmd_id
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local params
  params=$(jq -n --arg cmd "$cmd_string" '{"commands": [$cmd]}') \
    || { echo "ERROR: Failed to encode command as JSON" >&2; return 1; }

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "$params" \
    --timeout-seconds "$timeout" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  # Poll for completion
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$region" \
      --query 'Status' \
      --output text 2>/dev/null) || true
    case "$status" in
      Success)
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardOutputContent' \
          --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo "ERROR: Command $status" >&2
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardErrorContent' \
          --output text >&2
        return 1
        ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "ERROR: Timed out waiting for command result" >&2
  return 1
}

# --- SSM-based subcommands ---

cmd_status() {
  echo "Checking appserver status..."
  local stats
  stats=$(ssm_run "echo '=== Docker Containers ===' && docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' && echo && echo '=== Resources ===' && free -m | head -3 && echo && uptime && echo && df -h / | tail -1" 30 2>/dev/null) || {
    echo "Could not reach instance. Is it running?"
    return 1
  }
  echo "$stats"
}

cmd_ssh() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  aws ssm start-session --target "$instance_id" --region "$region"
}

cmd_logs() {
  local target="${1:-}"
  if [[ "$target" == "bootstrap" ]]; then
    ssm_run "tail -n 200 /var/log/appserver-bootstrap.log 2>/dev/null || echo 'No bootstrap log found at /var/log/appserver-bootstrap.log'" 60 || return 1
  elif [[ -n "$target" ]]; then
    [[ "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $target"
    ssm_run "cd /opt/appserver/apps/$target && docker compose logs --tail=100 2>&1" 60 || return 1
  else
    ssm_run "echo '=== Traefik ===' && docker logs --tail=30 traefik 2>&1 && for d in /opt/appserver/apps/*/; do [ -d \"\$d\" ] || continue; app=\$(basename \"\$d\"); echo && echo \"=== \$app ===\"; cd \"\$d\" && docker compose logs --tail=20 2>&1; done" 60 || return 1
  fi
}

cmd_app_deploy() {
  local app="${1:?Usage: appserver app deploy <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Deploying $app..."

  # Upload latest config
  package_and_upload_artifact

  local bucket region
  bucket="$(get_artifacts_bucket)"
  region="$(get_region)"

  # Pull config and deploy on instance
  ssm_run "
    set -e
    BUCKET='$bucket'
    REGION='$region'
    APP='$app'

    # Pull latest artifacts
    aws s3 cp \"s3://\$BUCKET/deploy/appserver-artifact.tar.gz\" /tmp/appserver-artifact.tar.gz --region \"\$REGION\" --quiet
    tar xzf /tmp/appserver-artifact.tar.gz -C /tmp/

    # Update app config (compose file)
    if [ -d \"/tmp/appserver-artifact/apps/\$APP\" ]; then
      mkdir -p /opt/appserver/apps/\$APP
      cp /tmp/appserver-artifact/apps/\$APP/docker-compose.yml /opt/appserver/apps/\$APP/ 2>/dev/null || true
      # Copy .env.example if no .env exists yet
      if [ ! -f /opt/appserver/apps/\$APP/.env ] && [ -f /tmp/appserver-artifact/apps/\$APP/.env.example ]; then
        cp /tmp/appserver-artifact/apps/\$APP/.env.example /opt/appserver/apps/\$APP/.env
        echo 'WARNING: Created .env from .env.example — edit secrets before starting!'
      fi
    else
      echo 'ERROR: No config found for app: '\$APP
      rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
      exit 1
    fi

    # Pull latest image and restart
    cd /opt/appserver/apps/\$APP
    docker compose pull 2>&1
    docker compose up -d 2>&1

    # Wait for containers to start
    sleep 5
    docker compose ps 2>&1

    rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
  " 120 || { echo "ERROR: Deploy failed on instance — check 'appserver logs $app'" >&2; return 1; }

  echo "$app deployed."
}

cmd_app_list() {
  ssm_run "for d in /opt/appserver/apps/*/; do [ -d \"\$d\" ] || continue; app=\$(basename \"\$d\"); status=\$(cd \"\$d\" && docker compose ps --format '{{.Name}}: {{.Status}}' 2>/dev/null); if [ -n \"\$status\" ]; then echo \"\$status\"; else echo \"\$app: not running\"; fi; done" 30
}

cmd_app_remove() {
  local app="${1:?Usage: appserver app remove <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Removing $app..."
  ssm_run "cd /opt/appserver/apps/$app && docker compose down && rm -rf /opt/appserver/apps/$app" 60
  echo "$app removed. Note: Docker volumes preserved. Remove manually if needed."
}

cmd_app_restart() {
  local app="${1:?Usage: appserver app restart <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"
  echo "Restarting $app..."
  ssm_run "cd /opt/appserver/apps/$app && docker compose restart 2>&1" 60
  echo "$app restarted."
}

cmd_app_init() {
  local app="${1:?Usage: appserver app init <name>}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid app name: $app"

  local app_config_dir="$CONFIG_DIR/apps/$app"
  if [[ ! -f "$app_config_dir/.env.example" ]]; then
    die "No .env.example found for app '$app' in config/apps/$app/"
  fi

  echo "Initializing $app..."
  echo

  # Generate cryptographically random secrets
  local postgres_password secret_key
  postgres_password=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32) \
    || die "Failed to generate POSTGRES_PASSWORD"
  secret_key=$(openssl rand -base64 64 | tr -d '/+=' | head -c 50) \
    || die "Failed to generate SECRET_KEY"

  echo "  Generated POSTGRES_PASSWORD (32 chars)"
  echo "  Generated SECRET_KEY (50 chars)"

  # Build the .env from the example, replacing placeholders
  local env_content
  env_content=$(sed \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" \
    -e "s|^SECRET_KEY=.*|SECRET_KEY=$secret_key|" \
    "$app_config_dir/.env.example") || die "Failed to process .env.example"

  # Remove comment lines starting with # (keep only actual env vars)
  env_content=$(echo "$env_content" | grep -v '^#' | grep -v '^$')

  # Merge local secrets file if it exists (upserts over .env.example values)
  local secrets_file="$app_config_dir/.env.secrets"
  if [[ -f "$secrets_file" ]]; then
    echo "  Merging secrets from $secrets_file"
    while IFS= read -r line; do
      [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
      local key="${line%%=*}"
      # Remove existing key then append (escape key for grep literal match)
      local escaped_key
      escaped_key=$(printf '%s' "$key" | sed 's/[.[\\*^$/]/\\&/g')
      env_content=$(echo "$env_content" | grep -v "^${escaped_key}=")
      env_content="$env_content"$'\n'"$line"
    done < "$secrets_file"
    # Clean up any blank lines
    env_content=$(echo "$env_content" | grep -v '^$')
  fi

  echo
  echo "Generated .env for $app:"
  # shellcheck disable=SC2001 # sed needed for per-line masking; ${//} is greedy across newlines
  echo "$env_content" | sed 's/=.*/=***/'
  echo

  # Upload to instance via SSM
  local env_b64
  env_b64=$(echo "$env_content" | base64 -w0) || die "Failed to encode .env"

  ssm_run "
    set -e
    mkdir -p /opt/appserver/apps/$app
    echo '$env_b64' | base64 -d > /opt/appserver/apps/$app/.env
    chmod 600 /opt/appserver/apps/$app/.env
    echo '.env written to /opt/appserver/apps/$app/.env'
  " 30 || die "Failed to upload .env to instance"

  local domain
  domain=$(sed -n 's/^domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null) || true
  [[ -z "$domain" ]] && domain="<your-domain>"

  echo "$app initialized. Next steps:"
  echo "  1. appserver app deploy $app"
  echo "  2. Visit https://$app.$domain"
  echo "  3. Register your first passkey (all users are peers — no admin tier in v1.43.0+)"
}

cmd_app_env() {
  local app="${1:?Usage: appserver app env <name> [KEY=VALUE ...]}"
  shift

  # Validate app name (alphanumeric + hyphens only)
  if [[ ! "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    die "Invalid app name: $app (must be lowercase alphanumeric with hyphens)"
  fi

  if [[ $# -eq 0 ]]; then
    # Show current env (mask values for security)
    ssm_run "if [ -f /opt/appserver/apps/$app/.env ]; then sed 's/=.*/=***/' /opt/appserver/apps/$app/.env; else echo 'No .env file found'; fi" 30
  else
    # Validate all KEY=VALUE pairs before sending
    for kv in "$@"; do
      if [[ ! "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]; then
        die "Invalid env var format: '$kv' (must be KEY=VALUE, key starts with letter/underscore)"
      fi
    done

    # Build env file content safely via base64
    local env_content
    env_content=$(printf '%s\n' "$@" | base64 -w0) || die "Failed to encode env vars"

    # Extract keys to remove existing entries (upsert, not append)
    local keys_b64
    keys_b64=$(printf '%s\n' "$@" | sed 's/=.*//' | base64 -w0)

    ssm_run "
      set -e
      mkdir -p /opt/appserver/apps/$app
      touch /opt/appserver/apps/$app/.env
      cp /opt/appserver/apps/$app/.env /tmp/appserver-env-new
      # Remove existing keys so we upsert rather than duplicate
      for key in \$(echo '$keys_b64' | base64 -d); do
        escaped_key=\$(printf '%s' \"\$key\" | sed 's/[.[\\\\*^$/]/\\\\&/g')
        sed -i \"/^\${escaped_key}=/d\" /tmp/appserver-env-new
      done
      echo '$env_content' | base64 -d >> /tmp/appserver-env-new
      mv /tmp/appserver-env-new /opt/appserver/apps/$app/.env
      chmod 600 /opt/appserver/apps/$app/.env
      echo 'Updated .env for $app. Run \"appserver app deploy $app\" to apply.'
    " 30
  fi
}

cmd_config_push() {
  # Pre-flight: warn if Cloudflare IP ranges have drifted
  check_cloudflare_ip_drift
  local ip_rc=$?
  if [ "$ip_rc" -eq 1 ]; then
    echo "WARNING: Cloudflare IP ranges in traefik.yml are out of date."
    if [ -n "$CF_IP_MISSING" ]; then
      echo "  Missing ranges — X-Forwarded-For will be silently stripped for some edge nodes."
      echo "$CF_IP_MISSING" | while read -r cidr; do echo "    + $cidr"; done
    fi
    echo "  Run 'appserver config check-ips --fix' first, or proceed at your own risk."
    echo ""
    read -rp "Push anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
  fi

  echo "Pushing config to instance..."
  package_and_upload_artifact

  local bucket region
  bucket="$(get_artifacts_bucket)"
  region="$(get_region)"

  ssm_run "
    set -e
    aws s3 cp 's3://$bucket/deploy/appserver-artifact.tar.gz' /tmp/appserver-artifact.tar.gz --region '$region' --quiet
    tar xzf /tmp/appserver-artifact.tar.gz -C /tmp/

    # Update traefik config and restart
    cp /tmp/appserver-artifact/traefik/* /opt/appserver/traefik/ 2>/dev/null || true
    cd /opt/appserver/traefik && docker compose up -d 2>&1

    # Update app compose files (does NOT restart apps — use 'app deploy' for that)
    for app_dir in /tmp/appserver-artifact/apps/*/; do
      [ -d \"\$app_dir\" ] || continue
      app=\$(basename \"\$app_dir\")
      mkdir -p /opt/appserver/apps/\$app
      cp \"\$app_dir\"docker-compose.yml /opt/appserver/apps/\$app/ 2>/dev/null || true
    done

    rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz
    echo 'Config updated. Use \"appserver app deploy <name>\" to restart apps.'
  " 60
}

cmd_users() {
  local out
  out=$(ssm_run "docker exec cookie-web python manage.py cookie_admin list-users --json 2>/dev/null" 30) \
    || { echo "Could not reach Cookie. Is the instance running?" >&2; return 1; }

  if ! echo "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "ERROR: cookie_admin list-users failed" >&2
    echo "$out" >&2
    return 1
  fi

  local count
  count=$(echo "$out" | jq '.users | length')
  echo "Cookie users ($count):"
  echo
  printf "%-16s %-8s %-10s %-10s %-12s %s\n" "Username" "User ID" "Passkeys" "Active" "Unlimited" "Joined"
  printf "%-16s %-8s %-10s %-10s %-12s %s\n" "--------" "-------" "--------" "------" "---------" "------"
  echo "$out" | jq -r '.users[] | [.username, .user_id, .passkeys, .is_active, .unlimited_ai, .date_joined] | @tsv' \
    | while IFS=$'\t' read -r username user_id passkeys active unlimited joined; do
        printf "%-16s %-8s %-10s %-10s %-12s %s\n" "$username" "$user_id" "$passkeys" "$active" "$unlimited" "$joined"
      done
}

# Top-level shortcut: unified health summary across instance, containers, Cookie,
# and the latest threat report. Designed for "is everything OK?" checks.
cmd_health() {
  echo "=== Instance ==="
  local instance_id region instance_state
  instance_id="$(get_instance_id)" || { echo "instance: unknown (terraform output unavailable)"; echo; }
  region="$(get_region)"
  if [[ -n "$instance_id" ]]; then
    instance_state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null) \
      || instance_state="unknown"
    echo "state: $instance_state"
  fi
  echo

  echo "=== Containers ==="
  ssm_run "docker ps --format 'table {{.Names}}\t{{.Status}}'" 30 2>/dev/null \
    || echo "could not reach instance"
  echo

  echo "=== Cookie ==="
  local cookie_out
  cookie_out=$(ssm_run "docker exec cookie-web python manage.py cookie_admin status --json 2>/dev/null && echo --- && docker ps --filter name=cookie-web --format '{{.Image}}' | sed 's/.*://'" 30 2>/dev/null) || cookie_out=""

  if [[ -n "$cookie_out" ]]; then
    local status_json version
    status_json=$(echo "$cookie_out" | sed -n '1,/^---$/p' | sed '$d')
    version=$(echo "$cookie_out" | sed -n '/^---$/,$p' | sed '1d' | head -1)

    local ok db users passkeys auth_mode
    ok=$(echo "$status_json" | jq -r '.ok // false' 2>/dev/null)
    db=$(echo "$status_json" | jq -r '.database // "?"' 2>/dev/null)
    users=$(echo "$status_json" | jq -r '.users.total // 0' 2>/dev/null)
    passkeys=$(echo "$status_json" | jq -r '.passkeys // 0' 2>/dev/null)
    auth_mode=$(echo "$status_json" | jq -r '.auth_mode // "?"' 2>/dev/null)

    echo "version:    $version"
    echo "status:     $([ "$ok" = "true" ] && echo "ok" || echo "DEGRADED")"
    echo "database:   $db"
    echo "auth mode:  $auth_mode"
    echo "users:      $users (passkeys: $passkeys)"
  else
    echo "could not reach Cookie"
  fi
  echo

  echo "=== Latest threat report ==="
  local reports_dir="$SCRIPT_DIR/../reports/threats"
  if [[ -d "$reports_dir" ]]; then
    local latest
    latest=$(find "$reports_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r | head -1)
    if [[ -n "$latest" && -f "$reports_dir/$latest/report.json" ]]; then
      local rstatus rfindings rrecs rtime
      rstatus=$(jq -r '.status' "$reports_dir/$latest/report.json")
      rfindings=$(jq '.findings | length' "$reports_dir/$latest/report.json")
      rrecs=$(jq '.recommendations | length' "$reports_dir/$latest/report.json")
      rtime=$(jq -r '.timestamp' "$reports_dir/$latest/report.json")
      echo "timestamp:       $rtime"
      echo "status:          $rstatus"
      echo "findings:        $rfindings"
      echo "recommendations: $rrecs"
    else
      echo "no reports yet — run 'appserver threats' to generate one"
    fi
  else
    echo "no reports yet — run 'appserver threats' to generate one"
  fi
}
