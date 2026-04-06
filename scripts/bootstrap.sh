#!/bin/bash
# shellcheck disable=SC2154,SC2034,SC1083  # Variables injected by Terraform templatefile() — $${} escaping hides usage from shellcheck

die() { echo "ERROR: $*" >&2; exit 1; }

LOG_FILE="/var/log/appserver-bootstrap.log"
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Appserver bootstrap started at $(date) ==="

REGION="${region}"
TUNNEL_TOKEN_SSM="${tunnel_token_ssm}"
CLOUDFLARED_VERSION="${cloudflared_version}"
CLOUDFLARED_SHA256="${cloudflared_sha256}"
DOCKER_COMPOSE_VERSION="${docker_compose_version}"
DOCKER_COMPOSE_SHA256="${docker_compose_sha256}"
ARTIFACTS_BUCKET="${artifacts_bucket}"

# Validate Terraform-injected variables
for var_name in REGION TUNNEL_TOKEN_SSM CLOUDFLARED_VERSION CLOUDFLARED_SHA256 DOCKER_COMPOSE_VERSION DOCKER_COMPOSE_SHA256 ARTIFACTS_BUCKET; do
  val="$${!var_name}"
  [[ -n "$val" ]] || die "$var_name is empty — check Terraform templatefile() variables"
done

# --- Swap (512MB) ---
if [[ ! -f /swapfile ]]; then
  echo "Creating swap..."
  dd if=/dev/zero of=/swapfile bs=1M count=512 || die "Failed to create swap"
  chmod 600 /swapfile
  mkswap /swapfile || die "Failed to mkswap"
  swapon /swapfile || die "Failed to swapon"
  echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
  sysctl vm.swappiness=10 || die "Failed to set swappiness"
  echo "vm.swappiness=10" >> /etc/sysctl.d/99-appserver.conf
  # Increase UDP buffers for cloudflared QUIC tunnel
  sysctl -w net.core.rmem_max=7500000 || die "Failed to set rmem_max"
  sysctl -w net.core.wmem_max=7500000 || die "Failed to set wmem_max"
  cat >> /etc/sysctl.d/99-appserver.conf <<SYSEOF
net.core.rmem_max=7500000
net.core.wmem_max=7500000
SYSEOF
else
  echo "Swap already exists, skipping."
fi

# --- Docker ---
echo "Installing Docker..."
dnf install -y docker || die "Failed to install Docker"

# Configure Docker log rotation (prevent unbounded log growth on 20GB EBS)
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKERCFG'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
DOCKERCFG

systemctl enable --now docker || die "Failed to start Docker"

# Docker Compose plugin (ARM, pinned version + SHA256 verification)
DOCKER_CONFIG=/usr/local/lib/docker
mkdir -p "$DOCKER_CONFIG/cli-plugins"
curl -fsSL --retry 3 --retry-delay 5 \
  "https://github.com/docker/compose/releases/download/$${DOCKER_COMPOSE_VERSION}/docker-compose-linux-aarch64" \
  -o "$DOCKER_CONFIG/cli-plugins/docker-compose" || die "Failed to download docker-compose"
echo "$${DOCKER_COMPOSE_SHA256}  $DOCKER_CONFIG/cli-plugins/docker-compose" | sha256sum -c - \
  || die "Docker Compose checksum mismatch (expected $${DOCKER_COMPOSE_SHA256})"
chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

# --- Directory structure ---
mkdir -p /opt/appserver/{traefik,apps}

# --- Cloudflared ---
echo "Installing cloudflared $${CLOUDFLARED_VERSION}..."
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/download/$${CLOUDFLARED_VERSION}/cloudflared-linux-arm64"
if ! curl -fsSL --retry 3 --retry-delay 5 "$CLOUDFLARED_URL" -o /tmp/cloudflared; then
  echo "GitHub download failed, trying S3 fallback..."
  aws s3 cp "s3://$${ARTIFACTS_BUCKET}/deploy/cloudflared-linux-arm64" /tmp/cloudflared --region "$REGION" \
    || die "Failed to download cloudflared from both GitHub and S3"
fi
echo "$${CLOUDFLARED_SHA256}  /tmp/cloudflared" | sha256sum -c - \
  || die "Cloudflared checksum mismatch (expected $${CLOUDFLARED_SHA256})"
install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared
rm -f /tmp/cloudflared

# Create cloudflared user
useradd -r -s /sbin/nologin cloudflared 2>/dev/null || true

# Get tunnel token from SSM (retry with backoff — SSM may not be ready immediately)
echo "Fetching tunnel token from SSM..."
TUNNEL_TOKEN=""
for attempt in 1 2 3 4 5; do
  TUNNEL_TOKEN=$(aws ssm get-parameter \
    --name "$TUNNEL_TOKEN_SSM" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$REGION" 2>/dev/null) && break
  echo "  Attempt $attempt failed, retrying in 10s..."
  sleep 10
done
[[ -n "$TUNNEL_TOKEN" ]] || die "Failed to get tunnel token from SSM after 5 attempts"

# Cloudflared environment file
mkdir -p /etc/cloudflared
(
  umask 077
  cat > /etc/cloudflared/env <<EOF
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF
)

# Cloudflared systemd unit
cat > /etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
User=cloudflared
EnvironmentFile=/etc/cloudflared/env
ExecStart=/usr/local/bin/cloudflared tunnel run
Restart=always
RestartSec=5
TimeoutStopSec=30

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
CapabilityBoundingSet=
SystemCallFilter=@system-service
MemoryMax=256M
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# --- Docker network for Traefik ---
docker network create appserver 2>/dev/null || true

# --- Pull artifacts from S3 ---
echo "Pulling artifacts from S3..."
if aws s3 cp "s3://$${ARTIFACTS_BUCKET}/deploy/appserver-artifact.tar.gz" /tmp/appserver-artifact.tar.gz --region "$REGION" 2>/dev/null; then
  # Verify checksum if available
  if aws s3 cp "s3://$${ARTIFACTS_BUCKET}/deploy/appserver-artifact.tar.gz.sha256" /tmp/appserver-artifact.tar.gz.sha256 --region "$REGION" 2>/dev/null; then
    (cd /tmp && sha256sum -c appserver-artifact.tar.gz.sha256) || die "Artifact checksum mismatch"
  fi

  tar xzf /tmp/appserver-artifact.tar.gz -C /tmp/

  # Traefik config
  cp /tmp/appserver-artifact/traefik/* /opt/appserver/traefik/ 2>/dev/null || true

  # App configs
  if [[ -d /tmp/appserver-artifact/apps ]]; then
    cp -r /tmp/appserver-artifact/apps/* /opt/appserver/apps/ 2>/dev/null || true
  fi

  rm -rf /tmp/appserver-artifact /tmp/appserver-artifact.tar.gz /tmp/appserver-artifact.tar.gz.sha256
  echo "Artifacts deployed."
else
  echo "No artifacts in S3 yet (first deploy). Creating default Traefik config..."
  cat > /opt/appserver/traefik/traefik.yml <<'TRAEFIK'
entryPoints:
  web:
    address: ":80"
    forwardedHeaders:
      trustedIPs:
        - "127.0.0.0/8"
        - "172.16.0.0/12"
        - "173.245.48.0/20"
        - "103.21.244.0/22"
        - "103.22.200.0/22"
        - "103.31.4.0/22"
        - "141.101.64.0/18"
        - "108.162.192.0/18"
        - "190.93.240.0/20"
        - "188.114.96.0/20"
        - "197.234.240.0/22"
        - "198.41.128.0/17"
        - "162.158.0.0/15"
        - "104.16.0.0/13"
        - "104.24.0.0/14"
        - "172.64.0.0/13"
        - "131.0.72.0/22"
        - "2400:cb00::/32"
        - "2606:4700::/32"
        - "2803:f800::/32"
        - "2405:b500::/32"
        - "2405:8100::/32"
        - "2a06:98c0::/29"
        - "2c0f:f248::/32"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: appserver
ping:
  entryPoint: traefik
log:
  level: WARN
TRAEFIK

  cat > /opt/appserver/traefik/docker-compose.yml <<'COMPOSE'
services:
  traefik:
    image: traefik:v3.4.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/appserver/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
    networks:
      - appserver

networks:
  appserver:
    external: true
    name: appserver
COMPOSE
fi

# --- Start Traefik ---
echo "Starting Traefik..."
cd /opt/appserver/traefik || die "Failed to cd to traefik directory"
docker compose up -d || die "Failed to start Traefik"

# --- Start cloudflared ---
echo "Starting cloudflared..."
systemctl daemon-reload
systemctl enable --now cloudflared || die "Failed to start cloudflared"

# --- Log rotation ---
cat > /etc/logrotate.d/appserver <<'LOGROTATE'
/var/log/appserver-bootstrap.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
}
LOGROTATE

mkdir -p /var/log/traefik
cat > /etc/logrotate.d/traefik <<'LOGROTATE'
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
LOGROTATE

# --- Deploy apps if configs exist ---
failed_apps=()
for app_dir in /opt/appserver/apps/*/; do
  [[ -d "$app_dir" ]] || continue
  app_name=$(basename "$app_dir")
  if [[ -f "$app_dir/docker-compose.yml" ]]; then
    echo "Deploying app: $app_name..."
    (cd "$app_dir" && docker compose up -d) || failed_apps+=("$app_name")
  fi
done

# shellcheck disable=SC2309 # $${} is Terraform templatefile escaping, not a bash expression
if [[ $${#failed_apps[@]} -gt 0 ]]; then
  echo "WARNING: Failed to start apps: $${failed_apps[*]}"
fi

echo "=== Appserver bootstrap complete at $(date) ==="
