# remote-state 입력 변수
# 계정 ID·IAM ARN이 들어가는 값은 bootstrap.auto.tfvars(.gitignore 대상)나 TF_VAR_로 넘긴다

variable "aws_region" {
  description = "State 버킷 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "bucket_prefix" {
  description = "버킷 이름 접두사. 실제 이름 = <prefix>-<계정ID>"
  type        = string
  default     = "neuroplan-tfstate"
}

variable "state_access_principal_arns" {
  description = "State 객체(tfstate, tflock) 읽기·쓰기를 허용할 IAM ARN. 지정 실행자(예린) + 비상 관리자. 비어 있으면 제한 없음"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.state_access_principal_arns : can(regex("^arn:aws:(iam|sts)::[0-9]{12}:", a))])
    error_message = "IAM 사용자/역할 ARN 형식이어야 합니다 (arn:aws:iam::<계정ID>:...)."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "이전 버전 state 보관 일수 (PSK가 담긴 과거 버전이 무기한 남지 않도록)"
  type        = number
  default     = 30
}
