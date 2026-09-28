terraform {
  required_version = ">= 1.10"

  # backend "s3" {
  #   bucket       = ""          # bootstrap/remote-state 생성 후 입력
  #   key          = "envs/prod/terraform.tfstate"
  #   region       = "ap-northeast-2"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
