resource "aws_dlm_lifecycle_policy" "appserver_snapshots" {
  description        = "Daily EBS snapshots for appserver instance"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    schedule {
      name = "daily-snapshot"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    target_tags = {
      Name = "appserver"
    }
  }
}

resource "aws_iam_role" "dlm" {
  name = "appserver-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "dlm.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
