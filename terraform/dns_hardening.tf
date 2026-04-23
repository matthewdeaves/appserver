# DNS/email hardening — addresses pentest LOW-1/2/3 findings (2026-04-19 HexStrike run).
# DNSSEC: zone-level signing; the DS record below must be pasted at the registrar
# before resolvers will validate. Until then the record is inert (not harmful).
resource "cloudflare_zone_dnssec" "this" {
  zone_id = var.cloudflare_zone_id
  status  = "active"
}

# CAA: only pki.goog (Cloudflare Universal SSL) and letsencrypt.org (GitHub Pages)
# may issue for this zone. iodef gives CAs a contact for policy violations.
resource "cloudflare_dns_record" "caa_issue_pki_goog" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = "issue"
    value = "pki.goog"
  }
}

resource "cloudflare_dns_record" "caa_issue_letsencrypt" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = "issue"
    value = "letsencrypt.org"
  }
}

resource "cloudflare_dns_record" "caa_iodef" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 1
  data = {
    flags = 0
    tag   = "iodef"
    value = "mailto:${var.admin_email}"
  }
}

# SPF: only iCloud is an authorised sender; hard-fail everything else.
resource "cloudflare_dns_record" "spf" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = 1
  content = "\"v=spf1 include:icloud.com -all\""
}

# DMARC: p=reject instructs receivers to discard mail that fails SPF/DKIM alignment.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.cloudflare_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 1
  content = "\"v=DMARC1; p=reject; rua=mailto:${var.admin_email}; ruf=mailto:${var.admin_email}; fo=1\""
}
