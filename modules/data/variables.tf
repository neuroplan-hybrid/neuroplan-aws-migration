variable "enabled" {
  description = "false이면 RDS 리소스를 생성하지 않습니다."
  type        = bool
  default     = false
}

variable "project_name" {
  description = "공통 태그에 사용할 프로젝트 이름입니다."
  type        = string
}

variable "environment" {
  description = "공통 태그에 사용할 환경 이름입니다."
  type        = string
}

variable "rds_mode" {
  description = "RDS 용도입니다. poc 또는 operation을 사용합니다."
  type        = string

  validation {
    condition     = contains(["poc", "operation"], var.rds_mode)
    error_message = "rds_mode는 poc 또는 operation이어야 합니다."
  }
}

variable "identifier" {
  description = "RDS DB instance identifier입니다."
  type        = string
}

variable "engine_version" {
  description = "AWS RDS에서 지원하는 MariaDB 엔진 버전입니다. On-Prem 버전과 동일하게 지정합니다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+", var.engine_version))
    error_message = "engine_version은 11.8.8과 같은 MariaDB 버전 형식이어야 합니다."
  }
}

variable "onprem_mariadb_version" {
  description = "양방향 복제·컷오버 대상 On-Prem MariaDB 버전입니다. major.minor는 RDS와 일치해야 합니다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+", var.onprem_mariadb_version))
    error_message = "onprem_mariadb_version은 11.8.8과 같은 MariaDB 버전 형식이어야 합니다."
  }
}

variable "instance_class" {
  description = "RDS 인스턴스 클래스입니다. 예: db.t4g.micro"
  type        = string
}

variable "allocated_storage" {
  description = "할당할 스토리지 용량(GiB)입니다."
  type        = number

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "RDS 할당 스토리지는 20GiB 이상이어야 합니다."
  }
}

variable "database_name" {
  description = "RDS 생성 시 만들 초기 DB 이름입니다. Dump Import로 생성할 경우 null을 사용합니다."
  type        = string
  default     = null
  nullable    = true
}

variable "master_username" {
  description = "RDS Master 사용자 이름입니다. 비밀번호는 RDS가 Secrets Manager에 자동 생성합니다."
  type        = string
}

variable "db_subnet_ids" {
  description = "Network 모듈이 제공하는 서로 다른 AZ의 Private DB Subnet ID 목록입니다."
  type        = list(string)

  validation {
    condition     = length(var.db_subnet_ids) >= 2
    error_message = "RDS DB Subnet Group에는 서로 다른 AZ의 Subnet을 최소 2개 전달해야 합니다."
  }
}

variable "db_subnet_group_name_prefix" {
  description = "생성할 DB Subnet Group 이름 접두사입니다. null이면 <identifier>-subnets-를 사용합니다."
  type        = string
  default     = null
  nullable    = true
}

variable "rds_security_group_ids" {
  description = "Network 모듈이 생성한 RDS Security Group ID 목록입니다."
  type        = list(string)
}

variable "parameter_group_name_prefix" {
  description = "생성할 사용자 지정 DB Parameter Group 이름 접두사입니다. null이면 <identifier>-params-를 사용합니다."
  type        = string
  default     = null
  nullable    = true
}

variable "parameter_group_family" {
  description = "RDS MariaDB 엔진 버전에 맞는 DB Parameter Group family입니다. MariaDB 11.8은 mariadb11.8을 사용합니다."
  type        = string
  default     = "mariadb11.8"
}

variable "parameter_group_parameters" {
  description = "사용자 지정 DB Parameter Group에 적용할 MariaDB 파라미터입니다. 값은 On-Prem 설정과 일치시킵니다."

  type = map(object({
    value        = string
    apply_method = string
  }))

  default = {
    binlog_format = {
      value        = "ROW"
      apply_method = "immediate"
    }
    character_set_server = {
      value        = "utf8mb4"
      apply_method = "pending-reboot"
    }
    collation_server = {
      value        = "utf8mb4_unicode_ci"
      apply_method = "pending-reboot"
    }
    time_zone = {
      value        = "Asia/Seoul"
      apply_method = "pending-reboot"
    }
  }
}

variable "multi_az" {
  description = "RDS Multi-AZ 활성화 여부입니다. PoC에서는 false를 사용합니다."
  type        = bool
}

variable "backup_retention_days" {
  description = "자동 백업 보존 기간(일)입니다. GTID 외부 복제를 위해 1일 이상이어야 합니다."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "자동 백업 보존 기간은 1일 이상이어야 합니다."
  }
}

variable "deletion_protection" {
  description = "RDS 삭제 보호 여부입니다. PoC 종료 시 제거할 수 있도록 false를 사용합니다."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "삭제 시 Final Snapshot을 생략할지 여부입니다. PoC에서는 true를 사용합니다."
  type        = bool
}

variable "final_snapshot_identifier" {
  description = "Final Snapshot 이름입니다. skip_final_snapshot=false일 때 필수입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "auto_minor_version_upgrade" {
  description = "자동 마이너 버전 업그레이드 여부입니다. PoC는 엔진 버전을 고정하므로 false를 사용합니다."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "수정 사항을 즉시 적용할지 여부입니다."
  type        = bool
  default     = false
}

variable "enable_cloudwatch_alarms" {
  description = "RDS CloudWatch Alarm·SNS 이메일 알림을 생성할지 여부입니다. 이메일 수신자를 확정하기 전에는 false로 유지합니다."
  type        = bool
  default     = false
}

variable "alarm_email_endpoints" {
  description = "RDS Alarm SNS Topic을 구독할 이메일 주소 목록입니다. 구독자는 AWS 발송 확인 이메일에서 구독을 승인해야 합니다."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_cloudwatch_alarms || length(var.alarm_email_endpoints) > 0
    error_message = "CloudWatch Alarm을 활성화하면 alarm_email_endpoints에 이메일 주소를 하나 이상 지정해야 합니다."
  }
}

variable "free_storage_alarm_threshold_bytes" {
  description = "FreeStorageSpace Alarm 임계값(Byte)입니다. 기본값은 4GiB입니다."
  type        = number
  default     = 4294967296

  validation {
    condition     = var.free_storage_alarm_threshold_bytes > 0
    error_message = "free_storage_alarm_threshold_bytes는 0보다 커야 합니다."
  }
}

variable "database_connections_alarm_threshold" {
  description = "DatabaseConnections Alarm 임계값입니다. 인스턴스 class·max_connections에 맞춰 조정합니다."
  type        = number
  default     = 80

  validation {
    condition     = var.database_connections_alarm_threshold > 0
    error_message = "database_connections_alarm_threshold는 0보다 커야 합니다."
  }
}

variable "tags" {
  description = "추가 태그입니다."
  type        = map(string)
  default     = {}
}
