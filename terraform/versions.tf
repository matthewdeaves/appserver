terraform {
  required_version = "~> 1.5"

  backend "s3" {
    # Bucket/region/use_lockfile set via -backend-config in appserver.sh deploy
    key     = "appserver/terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }
}
