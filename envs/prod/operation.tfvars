# 단계: operation

enable_rosa            = true
enable_ecr             = true
enable_vpn             = true
enable_rds             = true
rds_mode               = "operation"
enable_nat             = true
enable_dr_nlb          = true
enable_route53_routing = true

# 운영 RDS 기본 사양
# 비용 우선 기본값은 Single-AZ이다. T6 시연·RTO 측정 직전에
# rds_multi_az를 true로 변경하고 Plan/승인/Apply 후 Failover를 수행한다.
project_name              = "neuroplan"
environment               = "prod"
rds_identifier            = "neuroplan-rds-operation"
rds_engine_version        = "11.8.8"
onprem_mariadb_version    = "11.8.8"
rds_instance_class        = "db.t4g.micro"
rds_allocated_storage     = 20
rds_database_name         = null
rds_master_username       = "neuroplanadmin"
rds_multi_az              = false
rds_backup_retention_days = 7
rds_deletion_protection   = false

# 운영 RDS는 삭제 시 Final Snapshot을 남긴다.
# 실제 삭제 전에 날짜가 다른 고유한 이름으로 바꾼 뒤 Apply한다.
rds_skip_final_snapshot       = false
rds_final_snapshot_identifier = "neuroplan-rds-operation-final-20261020"

rds_auto_minor_version_upgrade = false
rds_apply_immediately          = false
