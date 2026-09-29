# 단계: poc

enable_rosa            = false
enable_ecr             = true
enable_vpn             = true
enable_rds             = true
rds_mode               = "poc"
enable_nat             = false
enable_dr_nlb          = true
enable_route53_routing = false

# RDS GTID 복제 PoC
# 네트워크 리소스는 이미 생성된 값을 참조만 한다.
project_name              = "neuroplan"
environment               = "prod"
rds_identifier            = "neuroplan-rds-poc"
rds_engine_version        = "11.8.8"
onprem_mariadb_version    = "11.8.8"
rds_instance_class        = "db.t4g.micro"
rds_allocated_storage     = 20
rds_database_name         = null
rds_master_username       = "neuroplanadmin"
rds_db_subnet_group_name  = "neuroplan-rds-poc-subnet-group"
rds_security_group_ids    = ["sg-08f1b12442c31925b"]
rds_multi_az              = false
rds_backup_retention_days = 1
rds_deletion_protection   = false
rds_skip_final_snapshot   = true

# PoC에서 엔진 버전 조건을 고정한다.
rds_auto_minor_version_upgrade = false
rds_apply_immediately          = false
