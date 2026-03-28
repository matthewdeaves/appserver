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
