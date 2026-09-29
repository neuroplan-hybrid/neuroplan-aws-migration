provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "NeuroPlan"
      ManagedBy = "Terraform"
      Component = "remote-state"
    }
  }
}
