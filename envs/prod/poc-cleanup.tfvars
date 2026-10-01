# 단계: poc-cleanup (VPN·DR NLB 유지, PoC RDS만 제거)
enable_rosa          = false
enable_ecr           = true
enable_vpn           = true
enable_rds           = false
rds_mode             = "poc" # enable_rds=false 이므로 미사용
enable_nat           = false
enable_dr_nlb        = true
route53_routing_mode = "off"
