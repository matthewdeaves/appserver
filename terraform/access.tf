# Cloudflare Access — email OTP for browser access, service token for CLI.
# Requests without valid authentication are blocked by Cloudflare at the edge.

resource "cloudflare_zero_trust_access_service_token" "appserver" {
  account_id = var.cloudflare_account_id
  name       = "appserver-cli"
}

resource "cloudflare_zero_trust_access_application" "appserver" {
  zone_id              = var.cloudflare_zone_id
  name                 = "Appserver"
  domain               = "${var.app_subdomains[0]}.${var.domain}"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  # Cover all app subdomains under a single Access application
  self_hosted_domains = [for s in var.app_subdomains : "${s}.${var.domain}"]

  policies = [
    {
      name     = "Allow CLI service token"
      decision = "non_identity"
      include  = [{ any_valid_service_token = {} }]
    },
    {
      name     = "Allow admin email (browser OTP)"
      decision = "allow"
      include  = [{ email = { email = var.admin_email } }]
    }
  ]
}