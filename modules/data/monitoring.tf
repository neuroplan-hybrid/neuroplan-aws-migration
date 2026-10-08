# RDS CloudWatch Alarm and SNS email delivery
#
# Alarm 판단은 AWS CloudWatch에서 수행한다. SNS Topic·Alarm만 Terraform으로
# 관리한다. 이메일 구독은 수신자 확인 전에는 Terraform으로 완전 삭제할 수 없으므로
# Apply 후 Topic ARN으로 CLI 또는 콘솔에서 별도 등록한다.

data "aws_caller_identity" "current" {
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0
}

resource "aws_sns_topic" "rds_alarms" {
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

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
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

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
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

  arn    = aws_sns_topic.rds_alarms[0].arn
  policy = data.aws_iam_policy_document.rds_alarms[0].json
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

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
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

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
  count = var.enabled && var.enable_cloudwatch_alarms ? 1 : 0

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
