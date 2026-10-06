variable "aws_region" {
  description = "AWS region used by the provider"
  type        = string
  default     = "ap-northeast-2"
}

variable "domain_name" {
  description = "Existing Route 53 public hosted zone name"
  type        = string
  default     = "neuroplan.cloud"
}
