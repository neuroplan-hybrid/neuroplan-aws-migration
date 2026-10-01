# edge 출력값 (다른 Module과는 envs/prod/main.tf에서 Input/Output으로만 연결)

# ---------- DR NLB ----------
output "dr_nlb_arn" {
  description = "DR NLB ARN (enable_dr_nlb=false면 null)"
  value       = try(aws_lb.dr[0].arn, null)
}

output "dr_nlb_dns_name" {
  description = "DR NLB DNS 이름 (도메인 전 PoC: curl --resolve 대상)"
  value       = try(aws_lb.dr[0].dns_name, null)
}

output "dr_nlb_zone_id" {
  description = "DR NLB Alias Hosted Zone ID"
  value       = try(aws_lb.dr[0].zone_id, null)
}

output "dr_target_group_arn" {
  description = "DR Target Group ARN (aws elbv2 describe-target-health 대상)"
  value       = try(aws_lb_target_group.dr[0].arn, null)
}

output "dr_nlb_security_group_id" {
  description = "DR NLB Security Group ID"
  value       = try(aws_security_group.dr_nlb[0].id, null)
}

# ---------- Route 53 ----------
output "app_fqdn" {
  description = "서비스 FQDN (k6·probe 대상). 라우팅 비활성 시 null"
  value       = local.app_fqdn
}

output "app_routing_policy" {
  description = "실제 생성된 app 레코드 정책 (weighted / failover / none)"
  value       = var.enable_route53_routing ? var.app_routing_policy : "none"
}

output "app_record_sites" {
  description = "app 레코드에 들어간 사이트 (rosa / onprem)"
  value       = keys(local.app_sites)
}

output "primary_health_fqdn" {
  description = "ROSA 헬스체크 대상 FQDN (ROSA Route host)"
  value       = local.create_primary_dns ? local.primary_health_fqdn : null
}

output "dr_health_fqdn" {
  description = "온프렘 헬스체크 대상 FQDN (NGF HTTPRoute hostname)"
  value       = local.create_dr_dns ? local.dr_health_fqdn : null
}

output "primary_health_check_id" {
  description = "ROSA 헬스체크 ID (CloudWatch HealthCheckStatus, us-east-1)"
  value       = try(aws_route53_health_check.primary[0].id, null)
}

output "dr_health_check_id" {
  description = "온프렘 헬스체크 ID (CloudWatch HealthCheckStatus, us-east-1)"
  value       = try(aws_route53_health_check.dr[0].id, null)
}
