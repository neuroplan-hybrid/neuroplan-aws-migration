terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0" # envs/prod·rosa와 동일 (PR #5 기준)
    }
  }
}
