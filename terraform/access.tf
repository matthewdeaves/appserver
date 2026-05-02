# Cloudflare Access — per-app policy:
#   public_app_subdomains → bypass (app handles auth itself)
#   all other app_subdomains → email OTP + service token

locals {
  public_apps    = toset([for s in var.app_subdomains : s if contains(var.public_app_subdomains, s)])
  protected_apps = toset([for s in var.app_subdomains : s if !contains(var.public_app_subdomains, s)])
}

resource "cloudflare_zero_trust_access_service_token" "appserver" {
  account_id = var.cloudflare_account_id
  name       = "appserver-cli"
}

# Public apps: CF Access bypassed — the app's own auth (passkeys etc.) is sufficient.
resource "cloudflare_zero_trust_access_application" "public_app" {
  for_each = local.public_apps

  zone_id              = var.cloudflare_zone_id
  name                 = "${each.key} (public)"
  type                 = "self_hosted"
  session_duration     = "0s"
  app_launcher_visible = false

  destinations = [{
    type = "public"
    uri  = "${each.key}.${var.domain}"
  }]

  policies = [{
    name     = "Public access"
    decision = "bypass"
    include  = [{ everyone = {} }]
  }]
}

# Protected apps: email OTP for browser; service token for CLI/pentest.
resource "cloudflare_zero_trust_access_application" "protected_app" {
  for_each = local.protected_apps

  zone_id              = var.cloudflare_zone_id
  name                 = each.key
  type                 = "self_hosted"
  session_duration     = "8760h"
  app_launcher_visible = false

  destinations = [{
    type = "public"
    uri  = "${each.key}.${var.domain}"
  }]

  policies = concat(
    [{
      name     = "Allow CLI service token"
      decision = "non_identity"
      include  = [{ any_valid_service_token = {} }]
    }],
    var.home_ip != "" ? [{
      name     = "Bypass from home IP"
      decision = "bypass"
      include  = [{ ip = { ip = "${var.home_ip}/32" } }]
    }] : [],
    [{
      name     = "Allow admin email (browser OTP)"
      decision = "allow"
      include  = [{ email = { email = var.admin_email } }]
    }]
  )
}

# security.txt bypass for protected apps only, scoped to exact path (fixes INFO-3).
# Public apps don't need this — the top-level bypass already covers all paths.
resource "cloudflare_zero_trust_access_application" "protected_app_well_known" {
  for_each = local.protected_apps

  zone_id              = var.cloudflare_zone_id
  name                 = "${each.key} security.txt bypass"
  type                 = "self_hosted"
  session_duration     = "0s"
  app_launcher_visible = false

  destinations = [{
    type = "public"
    uri  = "${each.key}.${var.domain}/.well-known/security.txt"
  }]

  policies = [{
    name     = "Bypass security.txt (RFC 9116)"
    decision = "bypass"
    include  = [{ everyone = {} }]
  }]
}
