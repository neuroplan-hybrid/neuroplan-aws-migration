output "key_id" {
  description = "KMS key ID used for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.key_id
}

output "key_arn" {
  description = "KMS key ARN used for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.arn
}

output "alias_name" {
  description = "KMS alias used for Vault auto-unseal"
  value       = aws_kms_alias.vault_unseal.name
}
