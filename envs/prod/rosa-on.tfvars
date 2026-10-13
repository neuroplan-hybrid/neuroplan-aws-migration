openshift_version = "4.20.40"
# 단계: rosa-on

enable_rosa          = true
enable_ecr           = true
enable_vpn           = true
enable_rds           = true
rds_mode             = "operation"
enable_nat           = true
enable_dr_nlb        = true
route53_routing_mode = "weighted" # 10/13 전환: LB DNS 입력과 같은 커밋 (#33, PR #49 리뷰 B안), 6-1 ROSA TLS preflight 통과(10/12)

# Route 53 Weighted (B안): 1013 #107 팀 결정 — Cutover 후 온프렘 DB는 읽기 전용이므로 실서비스는 처음부터 ROSA 1 / 온프렘 0
#   0/100·10/90·50/50은 격리 조건의 probe 측정에서만 (docs/runbooks/route53_weighted_steps_1013.md 5장)
# 10/13 전환 조건 (#28·#33·#34): ① ROSA Ingress LB DNS 확인 ② LB가 NLB가 아니면 primary_lb_zone_id 입력
#   ③ dr-health·primary-health /actuator/health/routing = 200 ④ plan에서 Route 53 레코드·헬스체크 생성 내용 확인
#   ⑤ ROSA TLS preflight 통과 (#59: Route externalCertificate·Router RBAC·외부 HTTPS SAN/Issuer) — 실패하면 off 유지 (weight 0도 양수 레코드가 모두 unhealthy면 응답 후보)
# ROSA Router NLB (openshift-ingress/router-default, Type=network → Zone ID는 모듈 기본 NLB 값 사용, 10/13 describe-load-balancers·태그 확인)
primary_lb_dns_name = "af7cae78d814d43e29f90033ed68a527-7820ebba64c0c69b.elb.ap-northeast-2.amazonaws.com"
rosa_weight         = 1
onprem_weight       = 0

# ROSA HCP Worker
# 공식 기본값과 비용 산정 기준을 명시적으로 고정한다.
compute_machine_type = "m5.xlarge"
rosa_replicas        = 3

# 운영 RDS 기본 사양
# PoC RDS와 별개로 생성한다. 운영 RDS는 Single-AZ를 유지하며,
# 데이터 보호 검증은 T3 PITR로 수행한다.
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

# RDS CloudWatch Alarm / SNS 이메일
# RDS 알람·SNS Topic·이벤트 구독만 추가되는지 기존 State에서 Plan 검토 후 승인된 Apply만 수행.
# 이 변경은 현재 적용 대상인 rosa-on 단계에 한정하며 operation.tfvars는 별도 승인 없이 변경하지 않는다.
# Apply 후 출력되는 SNS Topic ARN으로 이메일 구독을 별도 등록·승인한다.
enable_rds_cloudwatch_alarms = true
# 운영 RDS 실측 max_connections=30 (2026-10-13), 한도의 80%에서 사전 경고.
rds_database_connections_alarm_threshold = 24

# Managed Grafana (#98): AMG → VPN → Monitoring VM /32:9090 경로 + AMG SG. ROSA 운영 기간 검증, 10/16 이후 유지 여부는 별도 결정
enable_amg_onprem_prometheus = true
