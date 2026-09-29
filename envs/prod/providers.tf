provider "aws" {
  region = var.aws_region

  # 공통 태그 (IaC 가이드 9.3). Owner는 모듈 호출 시 tags로 지정
  default_tags {
    tags = {
      Project   = "NeuroPlan"
      ManagedBy = "Terraform"
    }
  }
}

provider "rhcs" {}
