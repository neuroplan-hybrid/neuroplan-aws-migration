# Observation/notification only. No VPN, NLB, DNS or DB mutation actions.
resource "aws_cloudwatch_metric_alarm" "vpn_tunnel_down" {
  for_each = var.vpn_tunnel_ips

  alarm_name          = "${var.project_name}-vpn-${each.key}-down"
  alarm_description   = "VPN redundancy degraded: this tunnel has no UP sample in the configured consecutive periods. T4 injection may be intentional."
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.evaluation_periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "missing"

  dimensions = {
    VpnId           = var.vpn_connection_id
    TunnelIpAddress = each.value
  }
  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
  tags          = { Owner = "junghyun", Severity = "warning", Scope = "vpn" }
}

resource "aws_cloudwatch_metric_alarm" "nlb_no_healthy_targets" {
  for_each = var.nlb_targets

  alarm_name          = "${var.project_name}-nlb-${each.key}-no-healthy-targets"
  alarm_description   = "NLB selected target group has zero healthy targets across reported samples. This is not an application transaction check."
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.evaluation_periods
  datapoints_to_alarm = var.evaluation_periods
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "missing"

  dimensions = {
    LoadBalancer = each.value.load_balancer
    TargetGroup  = each.value.target_group
  }
  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]
  tags          = { Owner = "junghyun", Severity = "critical", Scope = "nlb" }
}
