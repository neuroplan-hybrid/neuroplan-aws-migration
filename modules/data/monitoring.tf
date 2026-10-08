# RDS CloudWatch Alarm and SNS email delivery
#
# Alarm 판단은 AWS CloudWatch에서 수행한다. 이메일 주소는 tfvars에
# 기록하지 않고 로컬 secret tfvars 또는 TF_VAR_로 전달한다.
# SNS Email subscription은 수신자가 AWS 확인 메일을 승인하기 전까지
# pending confirmation 상태이며, 승인 전에는 알림이 전달되지 않는다.

data "aws_caller_identity" "current" {
  count = var.enable_cloudwatch_alarms ? 1 : 0
}

data "aws_region" "current" {
  count = var.enable_cloudwatch_alarms ? 1 : 0
}

resource "aws_sns_topic" "rds_alarms" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  name = "${var.identifier}-alarms"

  tags = merge(
    {
      Name        = "${var.identifier}-alarms"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      RdsMode     = var.rds_mode
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "rds_alarms" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  statement {
    sid    = "AllowAccountManagement"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current[0].account_id}:root"]
    }

    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:Receive",
    ]

    resources = [aws_sns_topic.rds_alarms[0].arn]
  }

  statement {
    sid    = "AllowCloudWatchAlarmPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.rds_alarms[0].arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current[0].account_id]
    }
  }

  statement {
    sid    = "AllowRdsEventPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.rds_alarms[0].arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current[0].account_id]
    }
  }
}

resource "aws_sns_topic_policy" "rds_alarms" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  arn    = aws_sns_topic.rds_alarms[0].arn
  policy = data.aws_iam_policy_document.rds_alarms[0].json
}

resource "aws_sns_topic_subscription" "rds_alarm_email" {
  for_each = var.enable_cloudwatch_alarms ? toset(var.alarm_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.rds_alarms[0].arn
  protocol  = "email"
  endpoint  = each.value

  endpoint_auto_confirms = false
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.identifier}-free-storage-low"
  alarm_description   = "RDS FreeStorageSpace is at or below the configured threshold."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = var.free_storage_alarm_threshold_bytes
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mariadb[0].identifier
  }

  alarm_actions = [aws_sns_topic.rds_alarms[0].arn]
  ok_actions    = [aws_sns_topic.rds_alarms[0].arn]

  tags = merge(
    {
      Name        = "${var.identifier}-free-storage-low"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      RdsMode     = var.rds_mode
    },
    var.tags,
  )
}

resource "aws_cloudwatch_metric_alarm" "rds_database_connections" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name          = "${var.identifier}-database-connections-high"
  alarm_description   = "RDS DatabaseConnections is at or above the configured threshold."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.database_connections_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mariadb[0].identifier
  }

  alarm_actions = [aws_sns_topic.rds_alarms[0].arn]
  ok_actions    = [aws_sns_topic.rds_alarms[0].arn]

  tags = merge(
    {
      Name        = "${var.identifier}-database-connections-high"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      RdsMode     = var.rds_mode
    },
    var.tags,
  )
}

resource "aws_db_event_subscription" "rds_events" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  name             = "${var.identifier}-events"
  sns_topic        = aws_sns_topic.rds_alarms[0].arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.mariadb[0].identifier]
  event_categories = ["availability", "failure", "maintenance"]
  enabled          = true

  depends_on = [aws_sns_topic_policy.rds_alarms]
}

output "alarm_sns_topic_arn" {
  description = "RDS CloudWatch Alarm 이메일 전달용 SNS Topic ARN"
  value       = try(aws_sns_topic.rds_alarms[0].arn, null)
}

output "cloudwatch_alarm_names" {
  description = "생성된 RDS CloudWatch Alarm 이름"
  value = compact([
    try(aws_cloudwatch_metric_alarm.rds_free_storage[0].alarm_name, null),
    try(aws_cloudwatch_metric_alarm.rds_database_connections[0].alarm_name, null),
  ])
}
