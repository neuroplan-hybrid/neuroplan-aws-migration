# envs/prod 출력값

# ---------- Network ----------
output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID (AZ 순)"
  value       = module.network.public_subnet_ids
}

output "private_rosa_subnet_ids" {
  description = "Private ROSA 서브넷 ID (AZ 순)"
  value       = module.network.private_rosa_subnet_ids
}

output "db_subnet_ids" {
  description = "Private DB 서브넷 ID (AZ 순)"
  value       = module.network.db_subnet_ids
}

output "rds_security_group_id" {
  description = "RDS Security Group ID"
  value       = module.network.rds_security_group_id
}

# ---------- Hybrid / S2S VPN ----------
output "vpn_connection_id" {
  description = "S2S VPN Connection ID (온프렘 점검 scripts/check_vpn_state_0930.sh --aws 인자). enable_vpn=false면 null"
  value       = module.hybrid.vpn_connection_id
}

output "vpn_tunnels" {
  description = "libreswan aws.conf 갱신용 (right = outside_ip). enable_vpn=false면 null"
  value       = module.hybrid.tunnels
}

output "vpn_tunnel_preshared_keys" {
  description = "터널 PSK (sensitive). 화면 출력 금지, Ansible Vault로만 전달"
  value       = module.hybrid.tunnel_preshared_keys
  sensitive   = true
}

# ---------- Edge / DR NLB ----------
output "dr_nlb_dns_name" {
  description = "DR NLB DNS 이름 (PoC curl --resolve 대상). enable_dr_nlb=false면 null"
  value       = module.edge.dr_nlb_dns_name
}

output "dr_target_group_arn" {
  description = "DR Target Group ARN (aws elbv2 describe-target-health). enable_dr_nlb=false면 null"
  value       = module.edge.dr_target_group_arn
}

output "dr_nlb_security_group_id" {
  description = "DR NLB Security Group ID. enable_dr_nlb=false면 null"
  value       = module.edge.dr_nlb_security_group_id
}

# ---------- Data / RDS ----------
output "rds_endpoint" {
  description = "RDS MariaDB endpoint"
  value       = try(module.data[0].rds_endpoint, null)
}

output "rds_port" {
  description = "RDS MariaDB port"
  value       = try(module.data[0].rds_port, null)
}

output "rds_db_subnet_group_name" {
  description = "Data 모듈이 생성한 RDS DB Subnet Group"
  value       = try(module.data[0].db_subnet_group_name, null)
}

output "rds_parameter_group_name" {
  description = "RDS에 연결된 사용자 지정 DB Parameter Group"
  value       = try(module.data[0].parameter_group_name, null)
}

output "rds_master_user_secret_arn" {
  description = "RDS Master 자격 증명이 저장된 Secrets Manager ARN"
  value       = try(module.data[0].master_user_secret_arn, null)
}
