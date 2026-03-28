# Monthly AWS budget alarm
resource "aws_budgets_budget" "monthly_total" {
  name         = "appserver-monthly-total"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.admin_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.admin_email]
  }
}

# Auto-recover instance on system status check failure
resource "aws_cloudwatch_metric_alarm" "auto_recovery" {
  alarm_name          = "appserver-auto-recovery"
  alarm_description   = "Auto-recover appserver instance on system status check failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  dimensions = {
    InstanceId = aws_instance.appserver.id
  }

  alarm_actions = [
    "arn:aws:automate:${var.region}:ec2:recover"
  ]

  tags = local.common_tags
}
