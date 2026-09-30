# network 출력값 (다른 Module과는 envs/prod/main.tf에서 Input/Output으로만 연결)

output "vpc_id" {
  description = "VPC ID (hybrid: VGW attach)"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR (rosa: machine_cidr, 온프렘 라우팅·방화벽 기준값)"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID 목록, AZ 순 (rosa: aws_subnet_ids, edge: DR NLB)"
  value       = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
}

output "private_rosa_subnet_ids" {
  description = "Private ROSA 서브넷 ID 목록, AZ 순 (rosa: aws_subnet_ids)"
  value       = [for k in sort(keys(aws_subnet.rosa)) : aws_subnet.rosa[k].id]
}

output "db_subnet_ids" {
  description = "Private DB 서브넷 ID 목록, AZ 순 (data: DB Subnet Group)"
  value       = [for k in sort(keys(aws_subnet.db)) : aws_subnet.db[k].id]
}

output "route_table_ids" {
  description = "라우팅 테이블 ID (hybrid: 온프렘 대역 → VGW 경로 추가)"
  value = {
    public = aws_route_table.public.id
    rosa   = aws_route_table.rosa.id
    db     = aws_route_table.db.id
  }
}

output "rds_security_group_id" {
  description = "RDS Security Group ID (data: RDS 인스턴스에 연결)"
  value       = aws_security_group.rds.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (enable_nat=false면 null)"
  value       = try(aws_nat_gateway.main[0].id, null)
}

output "s3_gateway_endpoint_id" {
  description = "S3 Gateway Endpoint ID (enable_s3_gateway_endpoint=false면 null)"
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}
