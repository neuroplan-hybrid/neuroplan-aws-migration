data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# No long-lived AWS credentials in Grafana. Use a read-only workspace role.
resource "aws_iam_role" "workspace" {
  name = "${var.name}-workspace"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:grafana:${var.region}:${data.aws_caller_identity.current.account_id}:/workspaces/*"
        }
      }
    }]
  })
  tags = { Owner = "junghyun" }
}

# Metric discovery/query APIs require Resource="*"; restrict to deployment region.
# No logs, secrets, DB, SNS Publish or infrastructure write permissions.
resource "aws_iam_role_policy" "cloudwatch" {
  name = "cloudwatch-metrics-read"
  role = aws_iam_role.workspace.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:DescribeAlarmsForMetric",
        "cloudwatch:DescribeAlarmHistory",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetMetricData",
        "ec2:DescribeRegions",
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "tag:GetResources"
      ]
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
    }]
  })
}

resource "aws_grafana_workspace" "this" {
  name                     = var.name
  description              = "Neuroplan hybrid monitoring; existing on-prem Grafana is retained"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.workspace.arn
  data_sources             = ["CLOUDWATCH"]
  # Declares AWS access only; Grafana data sources/dashboard provisioning is separate.
  # AWS selects a supported version for a new workspace.
  dynamic "vpc_configuration" {
    for_each = var.vpc_configuration == null ? [] : [var.vpc_configuration]
    content {
      subnet_ids         = vpc_configuration.value.subnet_ids
      security_group_ids = vpc_configuration.value.security_group_ids
    }
  }
  tags       = { Owner = "junghyun" }
  depends_on = [aws_iam_role_policy.cloudwatch]
}

resource "aws_grafana_role_association" "admin" {
  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  user_ids     = sort(tolist(var.admin_user_ids))
}
