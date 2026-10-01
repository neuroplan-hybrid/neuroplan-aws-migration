resource "aws_kms_key" "vault_unseal" {
  description             = "NeuroPlan Vault auto-unseal key"
  key_usage               = "ENCRYPT_DECRYPT"
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name = "neuroplan-vault-unseal"
  })
}

resource "aws_kms_alias" "vault_unseal" {
  name          = var.alias_name
  target_key_id = aws_kms_key.vault_unseal.key_id
}
