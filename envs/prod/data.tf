# envs/prod Data 모듈 통합
#
# 네트워크팀이 사전에 생성한 DB Subnet Group과 RDS Security Group을 입력으로만
# 참조한다. 이 Root는 VPC, VPN, Route Table, Security Group을 생성하거나 수정하지 않는다.

module "data" {
  # RDS가 꺼진 단계(poc-cleanup 등)에는 하위 모듈을 호출하지 않는다.
  count = var.enable_rds ? 1 : 0

  source = "../../modules/data"

  enabled      = true
  project_name = var.project_name
  environment  = var.environment
  rds_mode     = var.rds_mode

  identifier             = var.rds_identifier
  engine_version         = var.rds_engine_version
  onprem_mariadb_version = var.onprem_mariadb_version
  instance_class         = var.rds_instance_class
  allocated_storage      = var.rds_allocated_storage
  database_name          = var.rds_database_name
  master_username        = var.rds_master_username

  db_subnet_group_name   = var.rds_db_subnet_group_name
  rds_security_group_ids = var.rds_security_group_ids

  multi_az                  = var.rds_multi_az
  backup_retention_days     = var.rds_backup_retention_days
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_final_snapshot_identifier

  auto_minor_version_upgrade = var.rds_auto_minor_version_upgrade
  apply_immediately          = var.rds_apply_immediately
}

# Ansible의 논리 백업 Import 및 GTID 복제 설정에서 참조하는 값이다.
# Secret 값은 출력하지 않으며, Secrets Manager ARN만 노출한다.
output "rds_endpoint" {
  description = "RDS MariaDB endpoint"
  value       = try(module.data[0].rds_endpoint, null)
}

output "rds_port" {
  description = "RDS MariaDB port"
  value       = try(module.data[0].rds_port, null)
}

output "rds_parameter_group_name" {
  description = "RDS에 연결된 사용자 지정 DB Parameter Group"
  value       = try(module.data[0].parameter_group_name, null)
}

output "rds_master_user_secret_arn" {
  description = "RDS Master 자격 증명이 저장된 Secrets Manager ARN"
  value       = try(module.data[0].master_user_secret_arn, null)
}

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

variable "rds_db_subnet_group_name" {
  description = "사전 생성된 RDS DB Subnet Group 이름"
  type        = string
  default     = null
  nullable    = true
}

variable "rds_security_group_ids" {
  description = "사전 생성된 RDS Security Group ID 목록"
  type        = list(string)
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
