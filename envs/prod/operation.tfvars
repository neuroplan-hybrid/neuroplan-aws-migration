openshift_version = "4.20.40"
# 단계: operation

enable_rosa          = true
enable_ecr           = true
enable_vpn           = true
enable_rds           = true
rds_mode             = "operation"
enable_nat           = true
enable_dr_nlb        = true
route53_routing_mode = "weighted" # 10/13 rosa-on과 같은 커밋에서 LB DNS와 함께 전환

# Route 53 운영 (B안 active-passive): ROSA 1 / 온프렘 0 — ROSA 레코드가 모두 unhealthy일 때만 온프렘(DR NLB) 응답
# T6 Failback 동안은 ROSA 0 / 온프렘 1로 고정 (시나리오 4.10)
# weighted 전환 조건은 rosa-on.tfvars와 같음 (⑤ ROSA TLS preflight 통과, #59)
primary_lb_dns_name = "af7cae78d814d43e29f90033ed68a527-7820ebba64c0c69b.elb.ap-northeast-2.amazonaws.com" # rosa-on과 같은 값
rosa_weight         = 0
onprem_weight       = 1

# ROSA HCP Worker
# rosa-on과 동일한 타입/대수로 유지한다.
compute_machine_type = "m5.xlarge"
rosa_replicas        = 3

# 운영 RDS 기본 사양
# 운영 RDS는 Multi-AZ HA를 제안하며, 데이터 보호 검증은 T3 PITR로 수행한다.
project_name              = "neuroplan"
environment               = "prod"
rds_identifier            = "neuroplan-rds-operation"
rds_engine_version        = "11.8.8"
onprem_mariadb_version    = "11.8.8"
rds_instance_class        = "db.t4g.micro"
rds_allocated_storage     = 20
rds_database_name         = null
rds_master_username       = "neuroplanadmin"
rds_multi_az              = true
rds_backup_retention_days = 7
rds_deletion_protection   = false

# 운영 RDS는 삭제 시 Final Snapshot을 남긴다.
# 실제 삭제 전에 날짜가 다른 고유한 이름으로 바꾼 뒤 Apply한다.
rds_skip_final_snapshot       = false
rds_final_snapshot_identifier = "neuroplan-rds-operation-final-20261020"

rds_auto_minor_version_upgrade = false
rds_apply_immediately          = true

# #94 합의: rosa-on.tfvars와 동일한 RDS 알람 설정을 유지해 후속 operation Apply 시 삭제를 방지한다.
# CloudWatch Alarm / SNS 실제 적용은 별도 최종 Plan·승인 후 진행한다.
enable_rds_cloudwatch_alarms = true

# #115: VPN 2 + DR NLB 1 + ROSA HTTPS NLB 1 — already applied in production.
# Preserve these four alarms across operation/rosa-on plans. To avoid exposing
# infrastructure ARNs in Git, supply verified rosa_nlb_alarm_targets from the
# existing private network-alarms-on.tfvars.json (or approved auto.tfvars).
# Without the private targets, the Terraform validation intentionally fails closed.
enable_network_cloudwatch_alarms = true
# 운영 RDS 실측 max_connections=30 (2026-10-13)의 80%에서 사전 경고.
rds_database_connections_alarm_threshold = 24

# #113: 기존 온프렘 Grafana 재사용. AMG 전용 네트워크는 활성화하지 않는다.
enable_amg_onprem_prometheus = false
