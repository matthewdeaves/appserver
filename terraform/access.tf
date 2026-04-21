# Cloudflare Access — email OTP for browser access, service token for CLI.
# Requests without valid authentication are blocked by Cloudflare at the edge.

resource "cloudflare_zero_trust_access_service_token" "appserver" {
  account_id = var.cloudflare_account_id
  name       = "appserver-cli"
}

# Bypass CF Access for /.well-known/* so security.txt is publicly reachable
# per RFC 9116 §2.3. More-specific path match takes precedence over the
# hostname-wide application below.
resource "cloudflare_zero_trust_access_application" "appserver_well_known" {
  zone_id              = var.cloudflare_zone_id
  name                 = "Appserver .well-known bypass"
  type                 = "self_hosted"
  session_duration     = "0s"
  app_launcher_visible = false

  destinations = [for s in var.app_subdomains : {
    type = "public"
    uri  = "${s}.${var.domain}/.well-known/*"
  }]

  policies = [
    {
      name     = "Bypass .well-known (RFC 9116 public access)"
      decision = "bypass"
      include  = [{ everyone = {} }]
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "appserver" {
  zone_id              = var.cloudflare_zone_id
  name                 = "Appserver"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  destinations = [for s in var.app_subdomains : {
    type = "public"
    uri  = "${s}.${var.domain}"
  }]

  policies = concat(
    [
      {
        name     = "Allow CLI service token"
        decision = "non_identity"
        include  = [{ any_valid_service_token = {} }]
      },
    ],
    var.home_ip != "" ? [
      {
        name     = "Bypass from home IP"
        decision = "bypass"
        include  = [{ ip = { ip = "${var.home_ip}/32" } }]
      },
    ] : [],
    [
      {
        name     = "Allow admin email (browser OTP)"
        decision = "allow"
        include  = [{ email = { email = var.admin_email } }]
      }
    ]
  )
}