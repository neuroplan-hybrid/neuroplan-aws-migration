variable "force_delete" {
  description = "Allow ECR repositories to be deleted even when they contain images"
  type        = bool
  default     = true
}
