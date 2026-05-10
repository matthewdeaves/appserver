# DNS/email hardening — addresses pentest LOW-1/2/3 findings (2026-04-19 HexStrike run).
# DNSSEC: zone-level signing; the DS record (key_tag 2371, algorithm 13, digest type 2,
# digest BFDFF01455D500EFAD49AC2E3B8D2A2923F39906B2835D4C922B05E160E6E1DA) is at the
# .com registry under Cloudflare Registrar. CF preserves the per-zone keypair across
# disable/enable, so re-enabling restores the same DNSKEY and the existing DS keeps
# matching.
#
# WARNING: never `terraform destroy` this resource while the DS is still at the
# registry. Destroy removes the DNSKEY but leaves the DS orphaned, which makes every
# validating resolver (1.1.1.1, 8.8.8.8, 9.9.9.9) return SERVFAIL for the zone.
# Symptoms: LinkedIn Post Inspector reports "Bad DNS, bad gateway, or invalid server
# address" with status 0; the public site is unreachable for any client behind a
# DNSSEC-validating resolver. Recovery: re-activate via the API
# (PATCH /zones/{id}/dnssec {"status":"active"}) — the same DNSKEY comes back and
# the DS chain repairs in <1 min.
# Before reapplying after a destroy, import:
#   terraform import cloudflare_zone_dnssec.this <zone_id>
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
