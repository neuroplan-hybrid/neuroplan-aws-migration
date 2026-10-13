output "workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "workspace_url" {
  value = "https://${aws_grafana_workspace.this.endpoint}"
}

output "workspace_role_arn" {
  value = aws_iam_role.workspace.arn
}
