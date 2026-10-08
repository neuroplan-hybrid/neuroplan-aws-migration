openshift_version = "4.20.40"
# 단계: operation

enable_rosa          = true
enable_ecr           = true
enable_vpn           = true
enable_rds           = true
rds_mode             = "operation"
enable_nat           = true
enable_dr_nlb        = true
route53_routing_mode = "off" # TODO(10/13): "weighted" — rosa-on과 같은 커밋에서 LB DNS와 함께 전환

# Route 53 운영 (B안 active-passive): ROSA 1 / 온프렘 0 — ROSA 레코드가 모두 unhealthy일 때만 온프렘(DR NLB) 응답
# T6 Failback 동안은 ROSA 0 / 온프렘 1로 고정 (시나리오 4.10)
# weighted 전환 조건은 rosa-on.tfvars와 같음 (⑤ ROSA TLS preflight 통과, #59)
primary_lb_dns_name = null # TODO(10/13): ROSA Ingress LB DNS (rosa-on과 같은 값). weighted에서 null이면 validation이 plan 중단
rosa_weight         = 1
onprem_weight       = 0

# ROSA HCP Worker
# rosa-on과 동일한 타입/대수로 유지한다.
compute_machine_type = "m5.xlarge"
rosa_replicas        = 3

# 운영 RDS 기본 사양
# 운영 RDS는 Single-AZ를 유지하며, 데이터 보호 검증은 T3 PITR로 수행한다.
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

# rosa-on.tfvars와 같은 값으로 유지한다. 활성화는 별도 Plan·승인 후 진행한다.
enable_rds_cloudwatch_alarms = false
