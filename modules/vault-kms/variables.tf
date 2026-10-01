variable "alias_name" {
  description = "Alias for the Vault auto-unseal KMS key"
  type        = string
  default     = "alias/neuroplan-vault-unseal"
}

variable "deletion_window_in_days" {
  description = "KMS key deletion waiting period in days"
  type        = number
  default     = 30

  validation {
    condition = (
      var.deletion_window_in_days >= 7 &&
      var.deletion_window_in_days <= 30
    )
    error_message = "deletion_window_in_days는 7~30 사이여야 합니다."
  }
}

variable "tags" {
  description = "Additional tags for Vault KMS resources"
  type        = map(string)
  default     = {}
}
