output "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "name_servers" {
  description = "Authoritative name servers for neuroplan.cloud"
  value       = aws_route53_zone.main.name_servers
}
