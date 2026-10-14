variable "project_name" {
  type    = string
  default = "neuroplan"
}

variable "sns_topic_arn" {
  description = "Existing Seoul RDS alarm SNS topic; no topic or subscription is created"
  type        = string
  validation {
    condition     = can(regex("^arn:aws:sns:ap-northeast-2:[0-9]{12}:.+$", var.sns_topic_arn))
    error_message = "Use the existing ap-northeast-2 SNS topic ARN."
  }
}

variable "vpn_connection_id" {
  type = string
}

variable "vpn_tunnel_ips" {
  description = "Stable tunnel keys mapped to AWS outside IP addresses"
  type        = map(string)
  validation {
    condition     = length(var.vpn_tunnel_ips) == 2 && alltrue([for ip in values(var.vpn_tunnel_ips) : can(cidrhost("${ip}/32", 0))])
    error_message = "Provide the two VPN outside tunnel IP addresses."
  }
}

variable "nlb_targets" {
  description = "Stable keys and CloudWatch ARN suffixes, not full ARNs"
  type = map(object({
    load_balancer = string
    target_group  = string
  }))
  validation {
    condition = length(var.nlb_targets) > 0 && alltrue([
      for t in values(var.nlb_targets) :
      can(regex("^net/[^/]+/[^/]+$", t.load_balancer)) &&
      can(regex("^targetgroup/[^/]+/[^/]+$", t.target_group))
    ])
    error_message = "NLB dimensions require net/name/id and targetgroup/name/id suffixes."
  }
}

variable "evaluation_periods" {
  description = "Consecutive one-minute periods required to trigger"
  type        = number
  default     = 2
  validation {
    condition     = var.evaluation_periods >= 1 && var.evaluation_periods <= 5 && floor(var.evaluation_periods) == var.evaluation_periods
    error_message = "evaluation_periods must be an integer from 1 to 5."
  }
}
