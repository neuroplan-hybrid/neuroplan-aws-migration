# 단계: poc
enable_rosa          = false
enable_ecr           = true
enable_vpn           = true
enable_rds           = true
rds_mode             = "poc"
enable_nat           = false
enable_dr_nlb        = true
route53_routing_mode = "off"

# RDS GTID 복제 PoC
# DB Subnet Group과 RDS Security Group은 module.network Output으로 연결한다.
project_name              = "neuroplan"
environment               = "prod"
rds_identifier            = "neuroplan-rds-poc"
rds_engine_version        = "11.8.8"
onprem_mariadb_version    = "11.8.8"
rds_instance_class        = "db.t4g.micro"
rds_allocated_storage     = 20
rds_database_name         = null
rds_master_username       = "neuroplanadmin"
rds_multi_az              = false
rds_backup_retention_days = 1
rds_deletion_protection   = false
rds_skip_final_snapshot   = true

# PoC는 생성 직후 논리 백업 Import·GTID 복제를 진행하므로 즉시 적용한다.
rds_auto_minor_version_upgrade = false
rds_apply_immediately          = true
