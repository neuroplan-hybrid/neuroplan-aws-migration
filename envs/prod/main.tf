# envs/prod — 공통 조립 (PR 리뷰 필수)
# Apply 순서: network/hybrid/data/rosa → ROSA Ingress LB 확인 → edge
# 리소스 ON/OFF는 이 파일 수정이 아니라 단계별 tfvars 전환으로 한다.

# ---------- Network (희재) ----------
# VPC·서브넷·RT·RDS SG는 모든 단계에서 유지 (무료). NAT만 enable_nat로 ON/OFF

module "network" {
  source = "../../modules/network"

  enable_nat = var.enable_nat

  # RDS 3306 추가 허용 (ROSA 서브넷은 rds_allow_from_rosa로 자동 허용)
  # - 192.168.44.21: 기존 기본값 유지 (PoC 덤프·복제 설정)
  # - 192.168.44.51, .52: Cutover 후 On-Prem db-primary·db-replica → RDS 복제 (#18, ansible/README-rds-operation.md)
  # 규칙 키가 "extra-<CIDR>"라 기존 44.21 규칙은 교체되지 않고 2개만 추가됨
  rds_ingress_cidrs = ["192.168.44.21/32", "192.168.44.51/32", "192.168.44.52/32"]

  tags = { Owner = "heejae" }
}

# ---------- Hybrid / S2S VPN (희재) ----------
# VGW·CGW·경로는 유지, VPN Connection만 enable_vpn으로 ON/OFF

module "hybrid" {
  source = "../../modules/hybrid"

  vpc_id          = module.network.vpc_id
  route_table_ids = module.network.route_table_ids
  enable_vpn      = var.enable_vpn

  # null이면 AWS가 생성. 고정하려면 TF_VAR_vpn_tunnel1_preshared_key 로 전달 (IaC 가이드 5.1)
  tunnel1_preshared_key = var.vpn_tunnel1_preshared_key
  tunnel2_preshared_key = var.vpn_tunnel2_preshared_key

  tags = { Owner = "heejae" }
}

# ---------- Edge / DR NLB + Route 53 (희재) ----------
# DR NLB → VPN → 온프렘 VIP 192.168.24.100:443 (enable_dr_nlb)
# Route 53 헬스체크·레코드는 route53_routing_mode로 켬. PR #28 리뷰 조건에 따라
# primary-health·dr-health 호스트(/actuator/health/routing, #34)·인증서·라우팅 정책이 준비될 때까지 모든 단계 off.
# 켤 때 domain_name·hosted_zone_id·primary_lb_dns_name(ROSA LB)을 별도 tfvars PR로 추가
# (지금 켜면 모듈 validation이 domain_name·hosted_zone_id 누락으로 plan을 중단)

module "edge" {
  source = "../../modules/edge"

  enable_dr_nlb     = var.enable_dr_nlb
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  enable_route53_routing = var.route53_routing_mode != "off"
  app_routing_policy     = var.route53_routing_mode == "off" ? "none" : var.route53_routing_mode

  domain_name         = var.domain_name
  hosted_zone_id      = var.hosted_zone_id
  primary_lb_dns_name = var.primary_lb_dns_name
  primary_lb_zone_id  = var.primary_lb_zone_id
  rosa_weight         = var.rosa_weight
  onprem_weight       = var.onprem_weight

  tags = { Owner = "heejae" }
}

module "rosa" {
  count  = var.enable_rosa ? 1 : 0
  source = "../../modules/rosa"

  cluster_name         = var.cluster_name
  aws_subnet_ids       = concat(module.network.public_subnet_ids, module.network.private_rosa_subnet_ids)
  openshift_version    = var.openshift_version
  machine_cidr         = module.network.vpc_cidr
  compute_machine_type = var.compute_machine_type
  replicas             = var.rosa_replicas

  account_role_prefix  = var.account_role_prefix
  operator_role_prefix = var.operator_role_prefix
}

module "ecr" {
  count  = var.enable_ecr ? 1 : 0
  source = "../../modules/ecr"

  force_delete = var.ecr_force_delete
}

module "vault_kms" {
  count  = var.enable_vault_kms ? 1 : 0
  source = "../../modules/vault-kms"

  tags = {
    Owner = "yerin"
  }
}
