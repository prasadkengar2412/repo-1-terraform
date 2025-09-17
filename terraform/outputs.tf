output "m2m_client_ids" {
  value = { for k, v in aws_cognito_user_pool_client.m2m_clients : k => v.client_id }
}

output "m2m_client_secrets_secret_arns" {
  value = { for k, v in aws_secretsmanager_secret.m2m_secret : k => v.arn }
}
