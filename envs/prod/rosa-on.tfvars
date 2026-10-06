# 단계: rosa-on

enable_rosa          = true
enable_ecr           = true
enable_vpn           = true
enable_rds           = true
rds_mode             = "operation"
enable_nat           = true
enable_dr_nlb        = true
route53_routing_mode = "off" # TODO(10/13): "weighted" — LB DNS 입력과 같은 커밋에서만 전환 (#33, PR #49 리뷰 B안)

# Route 53 Weighted (전환 검증, B안): 시작 ROSA 0 / 온프렘 100 → 이후 가중치만 바꾸는 tfvars PR로 10/90 → 50/50
# 10/13 전환 조건 (#28·#33·#34): ① ROSA Ingress LB DNS 확인 ② LB가 NLB가 아니면 primary_lb_zone_id 입력
#   ③ dr-health·primary-health /actuator/health/routing = 200 ④ plan에서 Route 53 레코드·헬스체크 생성 내용 확인
primary_lb_dns_name = null # TODO(10/13): ROSA Ingress LB DNS
rosa_weight         = 0
onprem_weight       = 100

# ROSA HCP Worker
# 공식 기본값과 비용 산정 기준을 명시적으로 고정한다.
compute_machine_type = "m5.xlarge"
rosa_replicas        = 3

# 운영 RDS 기본 사양
# PoC RDS와 별개로 생성한다. 비용 우선 기본값은 Single-AZ이며,
# Multi-AZ 시연 전에는 operation.tfvars의 rds_multi_az만 true로 변경한다.
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
rds_apply_immediately          = true
