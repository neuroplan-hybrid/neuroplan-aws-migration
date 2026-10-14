mock_provider "aws" {}

variables {
  sns_topic_arn     = "arn:aws:sns:ap-northeast-2:123456789012:existing-rds-alarms"
  vpn_connection_id = "vpn-12345678"
  vpn_tunnel_ips = {
    tunnel1 = "203.0.113.10"
    tunnel2 = "203.0.113.11"
  }
  nlb_targets = {
    dr = {
      load_balancer = "net/dr/1234567890abcdef"
      target_group  = "targetgroup/dr/1234567890abcdef"
    }
    rosa-https = {
      load_balancer = "net/rosa/abcdef1234567890"
      target_group  = "targetgroup/rosa/abcdef1234567890"
    }
  }
}

run "four_notification_only_alarms" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.vpn_tunnel_down) == 2 && length(aws_cloudwatch_metric_alarm.nlb_no_healthy_targets) == 2
    error_message = "Expected two tunnel alarms and two NLB target group alarms."
  }
  assert {
    condition     = alltrue([for key, a in aws_cloudwatch_metric_alarm.vpn_tunnel_down : length(a.dimensions) == 1 && a.dimensions.TunnelIpAddress == var.vpn_tunnel_ips[key] && a.statistic == "Maximum" && a.datapoints_to_alarm == 2])
    error_message = "VPN alarms must use only the published TunnelIpAddress dimension and require consecutive down periods."
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.nlb_no_healthy_targets : a.namespace == "AWS/NetworkELB" && a.statistic == "Maximum" && a.threshold == 1])
    error_message = "NLB alarm must watch zero healthy targets using Maximum."
  }
  assert {
    condition     = alltrue([for a in concat(values(aws_cloudwatch_metric_alarm.vpn_tunnel_down), values(aws_cloudwatch_metric_alarm.nlb_no_healthy_targets)) : toset(a.alarm_actions) == toset([var.sns_topic_arn]) && toset(a.ok_actions) == toset([var.sns_topic_arn]) && a.treat_missing_data == "missing"])
    error_message = "All actions must notify only the existing SNS; missing metrics must not mean healthy."
  }
}

run "reject_other_region_topic" {
  command = plan
  variables {
    sns_topic_arn = "arn:aws:sns:us-east-1:123456789012:other"
  }
  expect_failures = [var.sns_topic_arn]
}

run "reject_full_arn_dimensions" {
  command = plan
  variables {
    nlb_targets = {
      dr = {
        load_balancer = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/net/dr/id"
        target_group  = "targetgroup/dr/id"
      }
    }
  }
  expect_failures = [var.nlb_targets]
}

run "reject_invalid_period" {
  command = plan
  variables {
    evaluation_periods = 0
  }
  expect_failures = [var.evaluation_periods]
}

