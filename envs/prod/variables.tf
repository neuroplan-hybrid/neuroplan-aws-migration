# 단계별 기능 스위치 (IaC 작업가이드 §2)

variable "enable_rosa" {
  type    = bool
  default = false
}

variable "enable_ecr" {
  type    = bool
  default = false
}

variable "enable_vpn" {
  type    = bool
  default = true
}

variable "enable_rds" {
  type    = bool
  default = false
}

variable "rds_mode" {
  type    = string
  default = "poc"

  validation {
    condition     = contains(["poc", "operation"], var.rds_mode)
    error_message = "rds_mode는 poc 또는 operation 이어야 합니다."
  }
}

variable "enable_nat" {
  type    = bool
  default = false
}

variable "enable_dr_nlb" {
  type    = bool
  default = true
}

variable "enable_route53_routing" {
  type    = bool
  default = false
}

# AWS
variable "aws_region" {
  description = "AWS region for NeuroPlan"
  type        = string
  default     = "ap-northeast-2"
}

# ROSA HCP
variable "cluster_name" {
  description = "ROSA HCP cluster name"
  type        = string
  default     = "neuroplan-rosa"
}

variable "account_role_prefix" {
  description = "Prefix for ROSA account IAM roles"
  type        = string
  default     = "neuroplan"
}

variable "operator_role_prefix" {
  description = "Prefix for ROSA operator IAM roles"
  type        = string
  default     = "neuroplan"
}

variable "openshift_version" {
  description = "OpenShift version for ROSA HCP"
  type        = string
  default     = null
}

variable "compute_machine_type" {
  description = "EC2 instance type for ROSA worker nodes"
  type        = string
  default     = null
}

variable "rosa_replicas" {
  description = "Number of ROSA worker nodes"
  type        = number
  default     = 3
}

# Hybrid / S2S VPN
# 값은 tfvars에 쓰지 않고 TF_VAR_ 로만 전달. sensitive와 무관하게 state에는 평문 저장 (IaC 가이드 5.1)
variable "vpn_tunnel1_preshared_key" {
  description = "VPN 터널 1 PSK (null이면 AWS 생성)"
  type        = string
  default     = null
  sensitive   = true
}

variable "vpn_tunnel2_preshared_key" {
  description = "VPN 터널 2 PSK (null이면 AWS 생성)"
  type        = string
  default     = null
  sensitive   = true
}

# ECR
variable "ecr_force_delete" {
  description = "Allow ECR repositories to be deleted with images during cleanup"
  type        = bool
  default     = true
}
