output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.appserver.id
  sensitive   = true
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "ssm_connect_command" {
  description = "Command to connect to the instance via SSM"
  value       = "aws ssm start-session --target ${aws_instance.appserver.id} --region ${var.region}"
  sensitive   = true
}

output "app_urls" {
  description = "App URLs"
  value       = { for s in var.app_subdomains : s => "https://${s}.${var.domain}" }
  sensitive   = true
}

output "cf_access_client_id" {
  description = "Cloudflare Access service token Client ID — use as CF-Access-Client-Id header"
  value       = cloudflare_zero_trust_access_service_token.appserver.client_id
  sensitive   = true
}

output "cf_access_client_secret" {
  description = "Cloudflare Access service token Client Secret — use as CF-Access-Client-Secret header"
  value       = cloudflare_zero_trust_access_service_token.appserver.client_secret
  sensitive   = true
}

# Operator role ARNs — consumed by `scripts/appserver.sh auth` to call
# sts:AssumeRole. Names are stable; ARNs include the account ID so the CLI
# doesn't need to know it ahead of time.
output "operator_role_readonly_arn" {
  description = "ARN of the read-only operator role"
  value       = aws_iam_role.appserver_readonly.arn
}

output "operator_role_cookie_ops_arn" {
  description = "ARN of the cookie-ops operator role"
  value       = aws_iam_role.appserver_cookie_ops.arn
}

output "operator_role_deploy_arn" {
  description = "ARN of the deploy operator role"
  value       = aws_iam_role.appserver_deploy.arn
}

# Paste this DS record at the domain registrar to complete DNSSEC activation.
# Until it's pasted, the zone-level DNSSEC resource is inert — resolvers ignore it.
output "dnssec_ds_record" {
  description = "DS record to paste at the registrar to activate DNSSEC"
  value = {
    algorithm   = cloudflare_zone_dnssec.this.algorithm
    key_tag     = cloudflare_zone_dnssec.this.key_tag
    digest_type = cloudflare_zone_dnssec.this.digest_type
    digest      = cloudflare_zone_dnssec.this.digest
    ds          = cloudflare_zone_dnssec.this.ds
  }
}
