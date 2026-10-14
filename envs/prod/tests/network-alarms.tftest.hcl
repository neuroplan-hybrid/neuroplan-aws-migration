mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_lb" {
    defaults = {
      arn                = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/net/rosa/abcdef1234567890"
      arn_suffix         = "net/rosa/abcdef1234567890"
      dns_name           = "rosa.elb.ap-northeast-2.amazonaws.com"
      load_balancer_type = "network"
    }
  }
  mock_data "aws_lb_target_group" {
    defaults = {
      arn_suffix         = "targetgroup/rosa/abcdef1234567890"
      load_balancer_arns = ["arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/net/rosa/abcdef1234567890"]
    }
  }
}
mock_provider "rhcs" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}

variables {
  enable_vpn    = false
  enable_dr_nlb = false
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(module.network_alarms) == 0
    error_message = "Unrelated infrastructure plans must not create network alarms."
  }
}

run "enabled_root_wiring" {
  command = plan
  variables {
    enable_network_cloudwatch_alarms = true
    enable_rds                       = true
    enable_rds_cloudwatch_alarms     = true
    enable_vpn                       = true
    enable_dr_nlb                    = true
    enable_rosa                      = true
    primary_lb_dns_name              = "rosa.elb.ap-northeast-2.amazonaws.com"
    rosa_nlb_alarm_targets = {
      https = {
        load_balancer_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/net/rosa/abcdef1234567890"
        target_group_arn  = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/rosa/abcdef1234567890"
      }
    }
  }
  override_module {
    target = module.rosa[0]
    outputs = {
      worker_role_arn = "arn:aws:iam::123456789012:role/mock-worker"
    }
  }
  override_module {
    target = module.data[0]
    outputs = {
      alarm_sns_topic_arn = "arn:aws:sns:ap-northeast-2:123456789012:existing-rds-alarms"
    }
  }
  override_module {
    target = module.hybrid
    outputs = {
      vpn_connection_id = "vpn-12345678"
      tunnels = {
        tunnel1 = { outside_ip = "203.0.113.10" }
        tunnel2 = { outside_ip = "203.0.113.11" }
      }
    }
  }
  override_module {
    target = module.edge
    outputs = {
      dr_nlb_arn          = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/net/dr/1234567890abcdef"
      dr_target_group_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/dr/1234567890abcdef"
    }
  }
  assert {
    condition     = length(module.network_alarms[0].alarm_names) == 4
    error_message = "Root must wire two tunnels, DR target group and ROSA target group."
  }
}
