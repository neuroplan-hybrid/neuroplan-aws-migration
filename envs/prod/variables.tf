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
# poc·poc-cleanup = off, rosa-on·operation = weighted (B안). 이관은 가중치 조정(ROSA 0 → 10 → 50), 운영은 ROSA 1 / 온프렘 0 (Weighted 기반 active-passive)
# 켜기 전 조건 (PR #28·#34): primary-health·dr-health의 /actuator/health/routing 200, 인증서(#45·#46)
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

# Route 53 라우팅 입력 (route53_routing_mode != off일 때 사용, #34·#43)
# 도메인·Hosted Zone은 bootstrap/dns(#36)로 고정된 값. Zone ID는 비밀값이 아님
variable "domain_name" {
  type    = string
  default = "neuroplan.cloud"
}

variable "hosted_zone_id" {
  type    = string
  default = "Z021384539IIHK7FGMEMN"
}

# ROSA Ingress LB (10/13 ROSA 생성 후 확인해 tfvars에 입력)
variable "primary_lb_dns_name" {
  type    = string
  default = null

  # B안 (#33, PR #49 리뷰): 라우팅은 ROSA LB 입력과 함께 한 번에 켬 → 온프렘만 먼저 켜는 부분 전환 방지
  validation {
    condition     = var.route53_routing_mode == "off" || var.primary_lb_dns_name != null
    error_message = "route53_routing_mode를 켜려면 primary_lb_dns_name(ROSA Ingress LB DNS)이 필요합니다. 온프렘만 먼저 켜지 않습니다 (B안)."
  }
}

# ROSA Ingress LB가 NLB가 아니면 지정 (null이면 리전 NLB Alias Zone ID)
variable "primary_lb_zone_id" {
  type    = string
  default = null
}

# Weighted 가중치 (B안): 전환 검증 0/100 → 10/90 → 50/50, 운영 1/0
variable "rosa_weight" {
  type    = number
  default = 0

  # ROSA 가중치가 0보다 크면 ROSA LB가 있어야 함 (없으면 ROSA 레코드가 만들어지지 않아 의도한 비율이 성립하지 않음, PR #49 리뷰)
  validation {
    condition     = var.route53_routing_mode == "off" || var.rosa_weight == 0 || var.primary_lb_dns_name != null
    error_message = "route53_routing_mode가 off가 아니고 rosa_weight > 0이면 primary_lb_dns_name(ROSA Ingress LB DNS)이 필요합니다."
  }
}

variable "onprem_weight" {
  type    = number
  default = 100

  # 라우팅을 켰을 때 응답할 레코드가 없거나 모두 가중치 0인 상태 방지
  validation {
    condition     = var.route53_routing_mode == "off" || var.rosa_weight + var.onprem_weight > 0
    error_message = "route53_routing_mode가 off가 아니면 rosa_weight + onprem_weight > 0 이어야 합니다."
  }
}

variable "enable_vault_kms" {
  description = "Create the AWS KMS key used for Vault auto-unseal"
  type        = bool
  default     = false
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

# RDS CloudWatch Alarm / SNS Email
# 이메일 구독은 Terraform으로 만들지 않으며, Apply 후 SNS Topic ARN으로 CLI 또는 콘솔에서 별도 등록·승인한다.
variable "enable_rds_cloudwatch_alarms" {
  description = "RDS CloudWatch Alarm·SNS Topic을 생성할지 여부"
  type        = bool
  default     = false
}

variable "rds_free_storage_alarm_threshold_bytes" {
  description = "RDS FreeStorageSpace Alarm 임계값(Byte)"
  type        = number
  default     = 4294967296
}

variable "rds_database_connections_alarm_threshold" {
  description = "RDS DatabaseConnections Alarm 임계값"
  type        = number
  default     = 80
}

# ECR
variable "ecr_force_delete" {
  description = "Allow ECR repositories to be deleted with images during cleanup"
  type        = bool
  default     = true
}
