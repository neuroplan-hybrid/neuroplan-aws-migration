# dns — 기존 Route 53 Public Hosted Zone을 Terraform state로 관리
# 이 bootstrap 리소스는 운영 중 destroy 대상에서 제외한다.

provider "aws" {
  region = var.aws_region
}

resource "aws_route53_zone" "main" {
  name          = var.domain_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true

    # 기존 콘솔 생성 Hosted Zone을 import하는 목적이므로
    # 기존 comment/tag를 Terraform이 임의로 덮어쓰지 않는다.
    ignore_changes = [
      comment,
      tags,
    ]
  }
}
