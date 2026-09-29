# envs/prod — 공통 조립 (PR 리뷰 필수)
# Apply 순서: network/hybrid/data/rosa → ROSA Ingress LB 확인 → edge
# 리소스 ON/OFF는 이 파일 수정이 아니라 단계별 tfvars 전환으로 한다.

module "rosa" {
  count  = var.enable_rosa ? 1 : 0
  source = "../../modules/rosa"

  aws_region           = var.aws_region
  cluster_name         = var.cluster_name
  aws_subnet_ids       = var.aws_subnet_ids
  openshift_version    = var.openshift_version
  account_role_prefix  = var.account_role_prefix
  operator_role_prefix = var.operator_role_prefix
}

module "ecr" {
  source = "../../modules/ecr"
}
