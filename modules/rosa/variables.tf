variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "ROSA HCP cluster name"
  type        = string
}

variable "aws_subnet_ids" {
  description = "Private subnet IDs for ROSA workers"
  type        = list(string)
}

variable "account_role_prefix" {
  description = "Prefix for ROSA account IAM roles"
  type        = string
}

variable "operator_role_prefix" {
  description = "Prefix for ROSA operator IAM roles"
  type        = string
}

variable "openshift_version" {
  description = "OpenShift version for ROSA HCP"
  type        = string
}
