# Cloudflare security hardening — free tier settings for public-facing apps.
# Bot Fight Mode is enabled via the dashboard (not manageable in free-tier Terraform).

# Defence-in-depth allowlist for CF-verified bots and known social/messaging
# crawlers — skips BIC/WAF/securityLevel/rateLimit/uaBlock/zoneLockdown/hot for
# them so a future hardening tweak can't accidentally break LinkedIn/X/Facebook
# link previews. Bot Fight Mode auto-allows verified bots already.
# Import the existing entrypoint ruleset before first apply:
#   terraform import cloudflare_ruleset.allow_social_bots zones/d98972eaff17dd8208bbb9708c59c917/8610dbe916e949bcbc85ba67731b2c54
resource "cloudflare_ruleset" "allow_social_bots" {
  zone_id     = var.cloudflare_zone_id
  name        = "default"
  description = ""
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [{
    ref         = "allow_verified_and_social_crawlers"
    description = "Skip BIC/WAF/security_level/rate_limit for CF-verified bots and known social/messaging crawlers (LinkedIn, X, Facebook, Slack, Discord, Telegram, WhatsApp, Pinterest, Mastodon, Bluesky)"
    expression  = "(cf.client.bot) or (lower(http.user_agent) contains \"linkedinbot\") or (lower(http.user_agent) contains \"twitterbot\") or (lower(http.user_agent) contains \"facebookexternalhit\") or (lower(http.user_agent) contains \"slackbot\") or (lower(http.user_agent) contains \"discordbot\") or (lower(http.user_agent) contains \"telegrambot\") or (lower(http.user_agent) contains \"whatsapp\") or (lower(http.user_agent) contains \"pinterestbot\") or (lower(http.user_agent) contains \"mastodon\") or (lower(http.user_agent) contains \"bluesky\")"
    action      = "skip"
    action_parameters = {
      products = ["bic", "securityLevel", "waf", "rateLimit", "uaBlock", "zoneLockdown", "hot"]
    }
    enabled = true
  }]
}

# Rate limiting — free plan: 1 rule, 10s period, IP-based only.
# Targets unauthenticated auth endpoints: passkey register/login, device code flow.
# Cookie also has Django-level rate limiting (10-20/hr per IP) as a second layer.
resource "cloudflare_ruleset" "rate_limiting" {
  zone_id     = var.cloudflare_zone_id
  name        = "Zone Rate Limiting"
  description = "Rate limit sensitive endpoints"
  kind        = "zone"
  phase       = "http_ratelimit"

  rules = [{
    ref         = "rate_limit_auth_endpoints"
    description = "Rate limit passkey auth and device code endpoints"
    expression  = "starts_with(http.request.uri.path, \"/api/auth/\")"
    action      = "block"
    ratelimit = {
      characteristics     = ["cf.colo.id", "ip.src"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
    enabled = true
  }]
}

# Zone security settings
resource "cloudflare_zone_setting" "browser_check" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "browser_check"
  value      = "on"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "tls_1_3" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

resource "cloudflare_zone_setting" "email_obfuscation" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "email_obfuscation"
  value      = "on"
}

# HSTS at the Cloudflare edge. Without this, CF defaults override Traefik's
# max-age=63072000;includeSubDomains;preload to max-age=15552000 (180 days, no
# preload flags) — see config/traefik/dynamic/security-headers.yml. Kept at
# 2 years to match Traefik; preload-eligible (>=1yr + includeSubDomains + preload).
resource "cloudflare_zone_setting" "security_header" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 63072000
      include_subdomains = true
      preload            = true
      nosniff            = true
    }
  }
}
