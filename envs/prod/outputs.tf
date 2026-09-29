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

output "vpn_tunnels" {
  description = "libreswan aws.conf 갱신용 (right = outside_ip). enable_vpn=false면 null"
  value       = module.hybrid.tunnels
}

output "vpn_tunnel_preshared_keys" {
  description = "터널 PSK (sensitive). 화면 출력 금지, Ansible Vault로만 전달"
  value       = module.hybrid.tunnel_preshared_keys
  sensitive   = true
}
