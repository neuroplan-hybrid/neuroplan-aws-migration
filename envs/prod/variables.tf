# 단계별 기능 스위치 (IaC 작업가이드 §2)

variable "enable_rosa" {
  type    = bool
  default = false
}

variable "enable_ecr" {
  type    = bool
  default = false
}

variable "enable_vpn" {
  type    = bool
  default = true
}

variable "enable_rds" {
  type    = bool
  default = false
}

variable "rds_mode" {
  type    = string
  default = "poc"

  validation {
    condition     = contains(["poc", "operation"], var.rds_mode)
    error_message = "rds_mode는 poc 또는 operation 이어야 합니다."
  }
}

variable "enable_nat" {
  type    = bool
  default = false
}

variable "enable_dr_nlb" {
  type    = bool
  default = true
}

# Route 53 app 레코드 라우팅 (Route 53 = GSLB, PR #22 결정 B)
# 현재: 4단계 모두 off (PR #28 리뷰 조건 — health 호스트·인증서·라우팅 정책 준비 후 별도 tfvars PR로 켬)
# 예정 (B안): 이관·운영 모두 weighted. 이관은 가중치 조정(ROSA 0 → 10 → 50), 운영은 ROSA 1 / 온프렘 0 (Weighted 기반 active-passive)
# off = 헬스체크·레코드 없음 / weighted = ROSA·온프렘(DR NLB) 가중치
# failover는 모듈 호환용으로 validation에만 남김 (사용 계획 없음, 같은 이름의 weighted 레코드와 공존 불가)
variable "route53_routing_mode" {
  type    = string
  default = "off"

  validation {
    condition     = contains(["off", "weighted", "failover"], var.route53_routing_mode)
    error_message = "route53_routing_mode는 off, weighted, failover 중 하나여야 합니다."
  }
}

# AWS
variable "aws_region" {
  description = "AWS region for NeuroPlan"
  type        = string
  default     = "ap-northeast-2"
}

# ROSA HCP
variable "cluster_name" {
  description = "ROSA HCP cluster name"
  type        = string
  default     = "neuroplan-rosa"
}

variable "account_role_prefix" {
  description = "Prefix for ROSA account IAM roles"
  type        = string
  default     = "neuroplan"
}

variable "operator_role_prefix" {
  description = "Prefix for ROSA operator IAM roles"
  type        = string
  default     = "neuroplan"
}

variable "openshift_version" {
  description = "OpenShift version for ROSA HCP"
  type        = string
  default     = null
}

variable "compute_machine_type" {
  description = "EC2 instance type for ROSA worker nodes"
  type        = string
  default     = null
}

variable "rosa_replicas" {
  description = "Number of ROSA worker nodes"
  type        = number
  default     = 3
}

# Hybrid / S2S VPN
# 값은 tfvars에 쓰지 않고 TF_VAR_ 로만 전달. sensitive와 무관하게 state에는 평문 저장.
variable "vpn_tunnel1_preshared_key" {
  description = "VPN 터널 1 PSK (null이면 AWS 생성)"
  type        = string
  default     = null
  sensitive   = true
}

variable "vpn_tunnel2_preshared_key" {
  description = "VPN 터널 2 PSK (null이면 AWS 생성)"
  type        = string
  default     = null
  sensitive   = true
}

# RDS Data
variable "project_name" {
  description = "공통 태그에 사용할 프로젝트 이름"
  type        = string
  default     = "neuroplan"
}

variable "environment" {
  description = "공통 태그에 사용할 환경 이름"
  type        = string
  default     = "prod"
}

variable "rds_identifier" {
  description = "RDS DB instance identifier"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_engine_version" {
  description = "AWS RDS MariaDB 엔진 버전"
  type        = string
  default     = null
  nullable    = true
}

variable "onprem_mariadb_version" {
  description = "GTID 복제·컷오버 대상 On-Prem MariaDB 버전"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_allocated_storage" {
  description = "RDS 할당 스토리지(GiB)"
  type        = number
  default     = null
  nullable    = true
}

variable "rds_database_name" {
  description = "RDS 생성 시 만들 초기 DB 이름. 논리 백업 Import로 만들면 null"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_master_username" {
  description = "RDS Master 사용자 이름. 비밀번호는 Secrets Manager가 자동 생성"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_multi_az" {
  description = "RDS Multi-AZ 활성화 여부"
  type        = bool
  default     = null
  nullable    = true
}

variable "rds_backup_retention_days" {
  description = "RDS 자동 백업 보존 기간(일)"
  type        = number
  default     = null
  nullable    = true
}

variable "rds_deletion_protection" {
  description = "RDS 삭제 보호 여부"
  type        = bool
  default     = null
  nullable    = true
}

variable "rds_skip_final_snapshot" {
  description = "RDS 삭제 시 Final Snapshot 생략 여부"
  type        = bool
  default     = null
  nullable    = true
}

variable "rds_final_snapshot_identifier" {
  description = "Final Snapshot 이름. skip_final_snapshot=false일 때 사용"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_auto_minor_version_upgrade" {
  description = "RDS 자동 마이너 버전 업그레이드 여부"
  type        = bool
  default     = null
  nullable    = true
}

variable "rds_apply_immediately" {
  description = "RDS 변경 사항 즉시 적용 여부"
  type        = bool
  default     = null
  nullable    = true
}

# ECR
variable "ecr_force_delete" {
  description = "Allow ECR repositories to be deleted with images during cleanup"
  type        = bool
  default     = true
}
