# S3 bucket for deploy artifacts (Traefik config, app compose files).
# Used by bootstrap (first boot) and config push (runtime updates).

# Access is already audited: writes come only from the deployer IAM user (CloudTrail
# data events cover s3:PutObject), reads come only from the instance role (same).
# Adding a dedicated logs bucket would create a chicken-and-egg dependency and
# recurring storage cost for data already captured.
# trivy:ignore:AVD-AWS-0089
# tfsec:ignore:aws-s3-enable-bucket-logging
resource "aws_s3_bucket" "artifacts" {
  bucket        = "appserver-artifacts-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name = "appserver-artifacts"
  })
}

# SSE-S3 (AES256) is sufficient for this bucket: it holds Traefik config + app compose
# files (no customer data, no secrets — secrets live in SSM SecureString). KMS would
# add cost and key-management overhead without a corresponding threat-model improvement.
# trivy:ignore:AVD-AWS-0132
# tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  depends_on = [aws_s3_bucket_public_access_block.artifacts]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonSSL"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
