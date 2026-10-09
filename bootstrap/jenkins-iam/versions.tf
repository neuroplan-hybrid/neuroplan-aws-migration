terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }
  }

  # Separate from envs/prod. The latter is intentionally destroyed on 10/16.
  backend "s3" {
    key          = "bootstrap/jenkins-iam/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project   = "NeuroPlan"
      ManagedBy = "Terraform"
      Component = "jenkins-iam"
    }
  }
}
