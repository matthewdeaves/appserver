resource "cloudflare_zero_trust_tunnel_cloudflared" "appserver" {
  account_id    = var.cloudflare_account_id
  name          = "appserver"
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

resource "random_password" "tunnel_secret" {
  length  = 32
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "appserver" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.appserver.id

  config = {
    ingress = [
      {
        # All subdomains route to Traefik, which handles Host-based routing
        hostname = "*.${var.domain}"
        service  = "http://localhost:80"
      },
      {
        service = "http_status:404"
      }
    ]
  }
}

# DNS records — one CNAME per app subdomain pointing to the tunnel
resource "cloudflare_dns_record" "app" {
  for_each = toset(var.app_subdomains)

  zone_id = var.cloudflare_zone_id
  name    = "${each.value}.${var.domain}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.appserver.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "appserver" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.appserver.id
}

resource "aws_ssm_parameter" "tunnel_token" {
  name  = "/appserver/tunnel-token"
  type  = "SecureString"
  value = data.cloudflare_zero_trust_tunnel_cloudflared_token.appserver.token

  tags = local.common_tags
}
