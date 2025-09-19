terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
  }
}

provider "aws" {
  region = var.region
}

# --- Pick UserPoolId from SSM depending on env ---
data "aws_ssm_parameter" "user_pool_id" {
  name = (
    var.env == "dev"  ? "/development/ULNG/UserPoolId" :
    var.env == "stg"  ? "/staging/ULNG/UserPoolId" :
    "/production/ULNG/UserPoolId"
  )
}

locals {
  user_pool_id = data.aws_ssm_parameter.user_pool_id.value

  # Load apps.json for environment
  apps_json = jsondecode(file("${path.root}/../${var.env}/apps.json"))
  apps_map  = { for c in local.apps_json : c.name => c }

  # Load customscopes.json if it exists
  customscope_file = "${path.root}/../customescope.json"
  customscopes     = fileexists(local.customscope_file) ? jsondecode(file(local.customscope_file)) : []
}

# --- Create Resource Servers + Scopes ---
resource "aws_cognito_resource_server" "servers" {
  for_each     = { for srv in local.customscopes : srv.identifier => srv }
  user_pool_id = local.user_pool_id
  identifier   = each.value.identifier
  name         = each.value.name

  dynamic "scope" {
    for_each = lookup(each.value, "scopes", [])
    content {
      scope_name        = scope.value
      scope_description = "${each.value.name} ${scope.value}"
    }
  }
}

# --- Create M2M App Clients ---
resource "aws_cognito_user_pool_client" "apps" {
  for_each     = local.apps_map
  name         = "ulng-m2mclient-${each.value.name}-${each.value.client_type}-${var.env}"
  user_pool_id = local.user_pool_id

  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  # Only custom scopes are valid in client_credentials grant
  allowed_oauth_scopes = lookup(each.value, "custom_scopes", [])

  # M2M apps do not need callback/logout URLs
  callback_urls = []
  logout_urls   = []

  # Token validity with safe defaults
  access_token_validity  = try(each.value.access_token_validity.value, 60)
  id_token_validity      = try(each.value.id_token_validity.value, 60)
  refresh_token_validity = try(each.value.refresh_token_validity.value, 30)

  token_validity_units {
    access_token  = try(each.value.access_token_validity.unit, "minutes")
    id_token      = try(each.value.id_token_validity.unit, "minutes")
    refresh_token = try(each.value.refresh_token_validity.unit, "days")
  }

  depends_on = [aws_cognito_resource_server.servers]

  lifecycle {
    create_before_destroy = true
  }
}

# --- Secrets Manager per App Client ---
resource "aws_secretsmanager_secret" "apps" {
  for_each = local.apps_map
  name     = "ulng-m2mclient-${each.value.name}-secrets-${each.value.client_type}-${var.env}"
}

resource "aws_secretsmanager_secret_version" "apps" {
  for_each = local.apps_map

  secret_id = aws_secretsmanager_secret.apps[each.key].id

  secret_string = jsonencode({
    client_id        = aws_cognito_user_pool_client.apps[each.key].id
    client_secret    = aws_cognito_user_pool_client.apps[each.key].client_secret
    authorizedscopes = aws_cognito_user_pool_client.apps[each.key].allowed_oauth_scopes
    client_type      = each.value.client_type
  })
}

# --- Cleanup Secrets on Destroy ---
resource "null_resource" "secret_cleanup" {
  for_each = aws_secretsmanager_secret.apps

  triggers = {
    secret_arn = each.value.arn
    region     = var.region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
      set -euo pipefail
      echo "ℹ️ Permanently deleting secret ${self.triggers.secret_arn}"
      aws secretsmanager delete-secret \
        --region "${self.triggers.region}" \
        --secret-id "${self.triggers.secret_arn}" \
        --force-delete-without-recovery 2>secret_cleanup_error.log || echo "Secret already deleted or not found"
      cat secret_cleanup_error.log
    EOT
  }

  depends_on = [aws_secretsmanager_secret.apps]
}

# --- Outputs ---
output "m2m_client_ids" {
  description = "Cognito Client IDs for all M2M apps"
  value       = { for k, v in aws_cognito_user_pool_client.apps : k => v.id }
}

output "m2m_client_secrets" {
  description = "Cognito Client Secrets for all M2M apps"
  sensitive   = true
  value       = { for k, v in aws_cognito_user_pool_client.apps : k => v.client_secret }
}
