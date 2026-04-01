# Common tags for all resources

locals {
  common_tags = {
    Project   = "appserver"
    ManagedBy = "terraform"
  }
}

# Data sources

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# IAM

resource "aws_iam_role" "appserver" {
  name = "appserver-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ssm_parameters" {
  name = "ssm-parameters"
  role = aws_iam_role.appserver.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters"
      ]
      Resource = [
        "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/appserver/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "s3_artifacts" {
  name = "s3-artifacts"
  role = aws_iam_role.appserver.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:HeadObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.appserver.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "appserver" {
  name = "appserver-instance-profile"
  role = aws_iam_role.appserver.name
}

# Security group — zero inbound, all outbound (traffic via Cloudflare Tunnel)

resource "aws_security_group" "appserver" {
  name        = "appserver-sg"
  description = "Appserver instance - no inbound, all outbound"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(local.common_tags, {
    Name = "appserver-sg"
  })
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.appserver.id
  description       = "All outbound - Docker pulls, Cloudflare Tunnel, SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EC2 instance

resource "aws_instance" "appserver" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.appserver.name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.appserver.id]

  user_data_base64 = base64gzip(templatefile("${path.module}/../scripts/bootstrap.sh", {
    region              = var.region
    tunnel_token_ssm    = aws_ssm_parameter.tunnel_token.name
    cloudflared_version = var.cloudflared_version
    artifacts_bucket    = aws_s3_bucket.artifacts.id
  }))

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  ebs_optimized = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  maintenance_options {
    auto_recovery = "default"
  }

  disable_api_termination = true

  tags = merge(local.common_tags, {
    Name        = "appserver"
    Environment = "production"
  })

  # user_data only runs on first boot — changes should NOT recreate the instance.
  # Use 'appserver config push' or 'appserver ssh' for runtime updates.
  lifecycle {
    ignore_changes = [user_data_base64]
  }
}
