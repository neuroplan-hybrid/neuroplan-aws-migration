# remote-state 출력값 → envs/prod backend 설정에 사용

output "state_bucket_name" {
  description = "State 버킷 이름 (envs/prod -backend-config=\"bucket=...\")"
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_region" {
  description = "State 버킷 리전"
  value       = var.aws_region
}

output "backend_config_hint" {
  description = "envs/prod·bootstrap backend partial config 예시 (계정 ID 포함 → 레포에 커밋하지 않음)"
  value       = "bucket=${aws_s3_bucket.state.bucket} region=${var.aws_region} use_lockfile=true encrypt=true"
}
