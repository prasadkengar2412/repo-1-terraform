output "m2m_client_ids" {
  description = "App client IDs created for M2M apps"
  value       = { for k, v in aws_cognito_user_pool_client.apps : k => v.client_id }
}
