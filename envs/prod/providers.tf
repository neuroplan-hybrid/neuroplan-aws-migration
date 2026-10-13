provider "aws" {
  region = var.aws_region

  # 공통 태그 (IaC 가이드 9.3). Owner는 모듈 호출 시 tags로 지정
  default_tags {
    tags = {
      Project   = "NeuroPlan"
      ManagedBy = "Terraform"
    }
  }

  # ROSA가 설치 시 Subnet에 직접 붙이는 클러스터 태그(kubernetes.io/cluster/<id>=shared)는 Terraform이 관리하지 않음
  # 없으면 Plan이 Public·ROSA Subnet 6개에서 이 태그를 제거하려 함 (#94 Plan) → Router NLB 서브넷 인식에 영향 가능
  # 모듈에 클러스터 ID를 하드코딩하지 않기 위해 provider 단에서 접두사로 무시
  ignore_tags {
    key_prefixes = ["kubernetes.io/cluster/"]
  }
}

provider "rhcs" {}
