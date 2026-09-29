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
  description = "State 객체(tfstate, tflock) 읽기·쓰기를 허용할 IAM ARN. 지정 실행자(예린) + 비상 관리자(계정 root 권장). 기본값 없음 = 필수 입력"
  type        = list(string)
  # default 없음: bootstrap.auto.tfvars를 빠뜨리면 plan 단계에서 입력을 요구하거나 실패 (fail-closed)

  validation {
    condition     = length(var.state_access_principal_arns) >= 2
    error_message = "지정 실행자와 비상 관리자 ARN을 최소 2개 입력해야 합니다 (접근 제한 Deny가 빠진 채 생성되는 것 방지)."
  }

  validation {
    condition     = alltrue([for a in var.state_access_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(root|user/.+|role/.+)$", a))])
    error_message = "IAM user/role 또는 계정 root ARN만 허용합니다 (arn:aws:iam::<계정ID>:root|user/...|role/...). STS assumed-role ARN은 사용하지 않습니다."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "이전 버전 state 보관 일수 (PSK가 담긴 과거 버전이 무기한 남지 않도록)"
  type        = number
  default     = 30
}
