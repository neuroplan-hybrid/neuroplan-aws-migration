# Workspace creation is opt-in and separate from #103 network activation.
variable "enable_amg_workspace" {
  description = "Create AMG workspace, read-only IAM role and Identity Center admin association"
  type        = bool
  default     = false
}

variable "amg_admin_user_ids" {
  description = "Existing IAM Identity Center user IDs (not IAM user kjh / ARN)"
  type        = set(string)
  default     = []
}

variable "enable_amg_vpc_connection" {
  description = "Connect AMG outbound traffic to existing ROSA private subnets and #103 SG"
  type        = bool
  default     = false
  validation {
    condition = !var.enable_amg_vpc_connection || (
      var.enable_amg_workspace && var.enable_amg_onprem_prometheus && var.enable_nat && var.enable_vpn
    )
    error_message = "AMG VPC connection requires workspace, #103 network, existing NAT and VPN to be enabled."
  }
}

module "amg_workspace" {
  count  = var.enable_amg_workspace ? 1 : 0
  source = "../../modules/amg"

  region         = var.aws_region
  admin_user_ids = var.amg_admin_user_ids
  # Existing network module sorts private ROSA subnets by AZ; reuse all three AZs.
  vpc_configuration = var.enable_amg_vpc_connection ? {
    subnet_ids         = module.network.private_rosa_subnet_ids
    security_group_ids = aws_security_group.amg[*].id
  } : null
}

output "amg_workspace_id" {
  value = try(module.amg_workspace[0].workspace_id, null)
}

output "amg_workspace_url" {
  value = try(module.amg_workspace[0].workspace_url, null)
}

output "amg_workspace_role_arn" {
  value = try(module.amg_workspace[0].workspace_role_arn, null)
}
