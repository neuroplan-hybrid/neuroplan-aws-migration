variable "cluster_name" {
  description = "ROSA HCP cluster name"
  type        = string
}

variable "aws_subnet_ids" {
  description = "Public and private subnet IDs for ROSA HCP"
  type        = list(string)
}

variable "machine_cidr" {
  description = "Machine CIDR for ROSA HCP"
  type        = string
}

variable "compute_machine_type" {
  description = "EC2 instance type for ROSA worker nodes"
  type        = string
  default     = null
}

variable "replicas" {
  description = "Number of ROSA worker nodes"
  type        = number
  default     = 3
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
