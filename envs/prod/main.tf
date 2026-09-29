# envs/prod — 공통 조립 (PR 리뷰 필수)
# Apply 순서: network/hybrid/data/rosa → ROSA Ingress LB 확인 → edge
# 리소스 ON/OFF는 이 파일 수정이 아니라 단계별 tfvars 전환으로 한다.

# ---------- Network (희재) ----------
# VPC·서브넷·RT·RDS SG는 모든 단계에서 유지 (무료). NAT만 enable_nat로 ON/OFF

module "network" {
  source = "../../modules/network"

  enable_nat = var.enable_nat

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
