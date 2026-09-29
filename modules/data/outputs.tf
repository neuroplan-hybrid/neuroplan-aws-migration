output "rds_identifier" {
  description = "생성된 RDS DB instance identifier입니다."
  value       = try(aws_db_instance.mariadb[0].identifier, null)
}

output "rds_endpoint" {
  description = "RDS Endpoint 주소입니다. Ansible GTID 복제 설정의 접속 대상으로 사용합니다."
  value       = try(aws_db_instance.mariadb[0].address, null)
}

output "rds_port" {
  description = "RDS MariaDB 포트입니다."
  value       = try(aws_db_instance.mariadb[0].port, null)
}

output "rds_arn" {
  description = "생성된 RDS DB instance ARN입니다."
  value       = try(aws_db_instance.mariadb[0].arn, null)
}

output "master_user_secret_arn" {
  description = "RDS가 생성한 Master 자격 증명의 Secrets Manager ARN입니다."
  value       = try(aws_db_instance.mariadb[0].master_user_secret[0].secret_arn, null)
}
