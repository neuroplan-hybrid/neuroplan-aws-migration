module "rosa_hcp" {
  source  = "terraform-redhat/rosa-hcp/rhcs"
  version = "1.7.5"

  cluster_name      = var.cluster_name
  openshift_version = var.openshift_version

  aws_subnet_ids = var.aws_subnet_ids

  create_account_roles = true
  account_role_prefix  = var.account_role_prefix

  create_oidc = true

  create_operator_roles = true
  operator_role_prefix  = var.operator_role_prefix
}
