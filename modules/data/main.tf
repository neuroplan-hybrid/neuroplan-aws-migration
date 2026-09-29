# RDS MariaDB module
#
# 네트워크 리소스(VPC, Subnet, VPN, Route Table, Security Group)는 만들거나 수정하지 않는다.
# envs/prod가 network 모듈의 Output을 이 모듈의 입력값으로 전달한다.

# 기본 DB Parameter Group은 수정할 수 없으므로, 복제·컷오버에 필요한
# binlog/문자셋/시간대 값을 적용할 수 있는 전용 그룹을 생성한다.
resource "aws_db_parameter_group" "mariadb" {
  count = var.enabled ? 1 : 0

  name        = coalesce(var.parameter_group_name, "${var.identifier}-params")
  family      = var.parameter_group_family
  description = "${var.project_name} ${var.rds_mode} MariaDB parameter group"

  dynamic "parameter" {
    for_each = var.parameter_group_parameters

    content {
      name         = parameter.key
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(
    {
      Name        = coalesce(var.parameter_group_name, "${var.identifier}-params")
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      RdsMode     = var.rds_mode
    },
    var.tags,
  )
}

resource "aws_db_instance" "mariadb" {
  count = var.enabled ? 1 : 0

  identifier     = var.identifier
  engine         = "mariadb"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  port              = 3306

  # 초기 스키마는 On-Prem 논리 백업을 Import하여 복원한다.
  db_name = var.database_name

  # RDS가 Master 비밀번호를 생성해 Secrets Manager에 보관한다.
  # 비밀번호를 Terraform 변수, tfvars, Git에 직접 넣지 않는다.
  username                    = var.master_username
  manage_master_user_password = true

  # network 모듈에서 생성한 기존 리소스만 참조한다.
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = var.rds_security_group_ids
  parameter_group_name   = aws_db_parameter_group.mariadb[0].name
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days
  deletion_protection     = var.deletion_protection

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : var.final_snapshot_identifier

  # PoC에서는 Source와 엔진 버전을 고정해 GTID 복제 검증 조건을 유지한다.
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = var.apply_immediately
  copy_tags_to_snapshot      = true

  tags = merge(
    {
      Name        = var.identifier
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      RdsMode     = var.rds_mode
    },
    var.tags,
  )

  lifecycle {
    precondition {
      condition     = var.engine_version == var.onprem_mariadb_version
      error_message = "RDS와 On-Prem MariaDB 버전은 양방향 복제·컷오버 전에 동일하게 맞춰야 합니다."
    }

    precondition {
      condition     = var.skip_final_snapshot || var.final_snapshot_identifier != null
      error_message = "skip_final_snapshot=false이면 final_snapshot_identifier를 지정해야 합니다."
    }
  }
}
