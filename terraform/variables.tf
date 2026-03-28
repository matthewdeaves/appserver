variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region))
    error_message = "Region must be a valid AWS region (e.g. eu-west-2)."
  }
}

variable "domain" {
  description = "Base domain (e.g. matthewdeaves.com)"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.domain))
    error_message = "Must be a valid domain."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "Must be a 32-character hex string."
  }
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "Must be a 32-character hex string."
  }
}

variable "instance_type" {
  description = "EC2 instance type (ARM/Graviton recommended for cost)"
  type        = string
  default     = "t4g.small"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+\\.[a-z0-9]+$", var.instance_type))
    error_message = "Must be a valid EC2 instance type (e.g. t4g.small)."
  }
}

variable "app_subdomains" {
  description = "List of app subdomains to create DNS records and routing for"
  type        = list(string)
  default     = ["cookie"]

  validation {
    condition     = length(var.app_subdomains) > 0
    error_message = "At least one app subdomain is required."
  }

  validation {
    condition     = alltrue([for s in var.app_subdomains : can(regex("^[a-z0-9][a-z0-9-]*$", s))])
    error_message = "Subdomains must be lowercase alphanumeric with hyphens."
  }
}

variable "admin_email" {
  description = "Email for Cloudflare Access OTP and budget alerts"
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.admin_email))
    error_message = "Must be a valid email address."
  }
}

variable "monthly_budget" {
  description = "Monthly AWS budget in USD"
  type        = number
  default     = 10

  validation {
    condition     = var.monthly_budget > 0
    error_message = "Must be greater than zero."
  }
}

variable "cloudflared_version" {
  description = "Cloudflared version to install (pinned for stability)"
  type        = string
  default     = "2026.3.0"
}
