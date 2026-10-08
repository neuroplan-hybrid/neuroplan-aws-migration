# envs/prod Data 모듈 통합
#
# Network 모듈의 DB Subnet·RDS Security Group Output을 받아 RDS 전용
# DB Subnet Group과 RDS를 Data 모듈에서 생성한다.

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

  db_subnet_ids = module.network.db_subnet_ids
  rds_security_group_ids = [
    module.network.rds_security_group_id
  ]

  multi_az                  = var.rds_multi_az
  backup_retention_days     = var.rds_backup_retention_days
  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_final_snapshot_identifier

  auto_minor_version_upgrade = var.rds_auto_minor_version_upgrade
  apply_immediately          = var.rds_apply_immediately

  enable_cloudwatch_alarms             = var.enable_rds_cloudwatch_alarms
  free_storage_alarm_threshold_bytes   = var.rds_free_storage_alarm_threshold_bytes
  database_connections_alarm_threshold = var.rds_database_connections_alarm_threshold

  tags = { Owner = "junghyun" }
}
