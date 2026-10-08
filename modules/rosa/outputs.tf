output "cluster_id" {
  description = "Unique identifier of the ROSA HCP cluster"
  value       = module.rosa_hcp.cluster_id
}

output "cluster_api_url" {
  description = "API server URL of the ROSA HCP cluster"
  value       = module.rosa_hcp.cluster_api_url
}

output "cluster_console_url" {
  description = "Web console URL of the ROSA HCP cluster"
  value       = module.rosa_hcp.cluster_console_url
}

output "cluster_state" {
  description = "Current state of the ROSA HCP cluster"
  value       = module.rosa_hcp.cluster_state
}

output "worker_role_arn" {
  description = "ARN of the ROSA HCP Worker IAM Role"
  value       = module.rosa_hcp.account_roles_arn["HCP-ROSA-Worker"]
}
