terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # version = "" # 팀에서 확정 후 고정
    }
  }
}
