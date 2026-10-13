variable "name" {
  type    = string
  default = "neuroplan-monitoring"
}

variable "region" {
  type = string
}

variable "admin_user_ids" {
  description = "Existing IAM Identity Center user IDs, not IAM usernames or ARNs"
  type        = set(string)
  validation {
    condition     = length(var.admin_user_ids) > 0 && alltrue([for id in var.admin_user_ids : length(trimspace(id)) > 0])
    error_message = "AMG requires at least one existing IAM Identity Center administrator user ID."
  }
}

variable "vpc_configuration" {
  description = "Optional outbound connection; null supports CloudWatch-first setup without VPC"
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
  validation {
    condition = var.vpc_configuration == null ? true : (
      length(distinct(var.vpc_configuration.subnet_ids)) >= 2 &&
      length(var.vpc_configuration.security_group_ids) >= 1
    )
    error_message = "AMG VPC connection requires two distinct private subnets in different AZs and a security group."
  }
}
