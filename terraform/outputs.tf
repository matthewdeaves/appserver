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
