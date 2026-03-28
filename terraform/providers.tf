provider "aws" {
  region = var.region
}

provider "cloudflare" {
  # Uses CLOUDFLARE_API_TOKEN environment variable
}
