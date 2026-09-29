terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44.0" # envs/prod와 동일
    }
  }

  # 최초 1회는 local state로 생성한 뒤, 아래 backend를 켜고 S3로 migrate한다 (README 2~3단계)
  # 버킷 이름에 계정 ID가 들어가 공개 레포에 쓰지 않도록 partial config(-backend-config)로 넘긴다
  backend "s3" {}
}
