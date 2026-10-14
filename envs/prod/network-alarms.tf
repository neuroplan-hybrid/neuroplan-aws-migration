variable "enable_network_cloudwatch_alarms" {
  description = "Opt-in Seoul VPN/NLB alarms using the existing RDS SNS topic"
  type        = bool
  default     = false
  validation {
    condition = !var.enable_network_cloudwatch_alarms || (
      var.aws_region == "ap-northeast-2" &&
      var.enable_rds && var.enable_rds_cloudwatch_alarms &&
      var.enable_vpn && var.enable_dr_nlb
    )
    error_message = "Network alarms require Seoul, existing RDS/SNS alarms, VPN and DR NLB enabled."
  }
}

variable "rosa_nlb_alarm_targets" {
  description = "Verified ROSA NLB and target group ARNs; keys such as https remain stable"
  type = map(object({
    load_balancer_arn = string
    target_group_arn  = string
  }))
  default = {}
  validation {
    condition     = !var.enable_network_cloudwatch_alarms || !var.enable_rosa || length(var.rosa_nlb_alarm_targets) > 0
    error_message = "When ROSA is enabled, provide its actual NLB/target group ARNs before enabling network alarms."
  }
  validation {
    condition = alltrue([
      for t in values(var.rosa_nlb_alarm_targets) :
      can(regex("^arn:aws:elasticloadbalancing:ap-northeast-2:[0-9]{12}:loadbalancer/net/[^/]+/[^/]+$", t.load_balancer_arn)) &&
      can(regex("^arn:aws:elasticloadbalancing:ap-northeast-2:[0-9]{12}:targetgroup/[^/]+/[^/]+$", t.target_group_arn))
    ])
    error_message = "Use actual Seoul network load balancer and target group ARNs, not DNS names."
  }
}

variable "network_alarm_evaluation_periods" {
  type    = number
  default = 2
}

# Read-only lookup: never import/manage ROSA-owned load balancer resources.
data "aws_lb" "rosa_alarm" {
  for_each = var.enable_network_cloudwatch_alarms && var.enable_rosa ? var.rosa_nlb_alarm_targets : {}
  arn      = each.value.load_balancer_arn
  lifecycle {
    postcondition {
      condition = self.load_balancer_type == "network" && (
        trimsuffix(self.dns_name, ".") == trimsuffix(coalesce(var.primary_lb_dns_name, "not-configured"), ".")
      )
      error_message = "ROSA alarm NLB must match the current primary_lb_dns_name."
    }
  }
}

data "aws_lb_target_group" "rosa_alarm" {
  for_each = var.enable_network_cloudwatch_alarms && var.enable_rosa ? var.rosa_nlb_alarm_targets : {}
  arn      = each.value.target_group_arn
  lifecycle {
    postcondition {
      condition     = contains(self.load_balancer_arns, data.aws_lb.rosa_alarm[each.key].arn)
      error_message = "ROSA target group must belong to the selected ROSA NLB."
    }
  }
}

module "network_alarms" {
  count  = var.enable_network_cloudwatch_alarms ? 1 : 0
  source = "../../modules/network-alarms"

  project_name      = var.project_name
  sns_topic_arn     = try(module.data[0].alarm_sns_topic_arn, "")
  vpn_connection_id = module.hybrid.vpn_connection_id
  vpn_tunnel_ips = {
    tunnel1 = try(module.hybrid.tunnels.tunnel1.outside_ip, "")
    tunnel2 = try(module.hybrid.tunnels.tunnel2.outside_ip, "")
  }
  nlb_targets = merge({
    dr = {
      load_balancer = try(regex("loadbalancer/(net/[^/]+/[^/]+)$", module.edge.dr_nlb_arn)[0], "")
      target_group  = try(regex("(targetgroup/[^/]+/[^/]+)$", module.edge.dr_target_group_arn)[0], "")
    }
    }, {
    for key, t in data.aws_lb_target_group.rosa_alarm : "rosa-${key}" => {
      load_balancer = data.aws_lb.rosa_alarm[key].arn_suffix
      target_group  = t.arn_suffix
    }
  })
  evaluation_periods = var.network_alarm_evaluation_periods
}

output "network_cloudwatch_alarm_names" {
  value = try(module.network_alarms[0].alarm_names, [])
}
