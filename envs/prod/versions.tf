terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0"
    }

    rhcs = {
      source  = "terraform-redhat/rhcs"
      version = "~> 1.7.9"
    }
  }

  backend "s3" {}
}
