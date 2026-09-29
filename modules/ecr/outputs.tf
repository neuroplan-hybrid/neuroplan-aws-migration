output "frontend_repository_url" {
  description = "ECR repository URL for NeuroPlan frontend"
  value       = aws_ecr_repository.frontend.repository_url
}

output "backend_repository_url" {
  description = "ECR repository URL for NeuroPlan backend"
  value       = aws_ecr_repository.backend.repository_url
}
