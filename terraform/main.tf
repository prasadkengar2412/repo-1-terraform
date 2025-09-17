terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Pick UserPoolId SSM path dynamically
locals {
  ssm_path = (
    var.env == "dev"  ? "/development/ULNG/UserPoolId" :
    var.env == "stg"  ? "/staging/ULNG/UserPoolId" :
    var.env == "prod" ? "/production/ULNG/UserPoolId" :
    ""
  )
}

data "aws_ssm_parameter" "userpool_id" {
  name = local.ssm_path
}

locals {
  user_pool_id = data.aws_ssm_parameter.userpool_id.value

  apps_json = jsondecode(file("${path.root}/../${var.env}/apps.json"))
  apps_map  = { for c in local.apps_json : c.name => c }

  customscope_file = "${path.module}/customscope.json"
  customscopes     = fileexists(local.customscope_file) ? jsondecode(file(local.customscope_file)) : []
}

# --- Resource Servers (from customscope.json) ---
resource "aws_cognito_resource_server" "servers" {
  for_each   = { for srv in local.customscopes : srv.identifier => srv }
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

# --- App Clients (from apps.json) ---
resource "aws_cognito_user_pool_client" "apps" {
  for_each     = local.apps_map
  name         = each.key
  user_pool_id = local.user_pool_id

  generate_secret = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows = ["client_credentials"]

  allowed_oauth_scopes = concat(
    lookup(each.value, "scopes", []),
    lookup(each.value, "custom_scopes", [])
  )

  callback_urls = lookup(each.value, "redirect_urls", [])
  logout_urls   = lookup(each.value, "logout_urls", [])

  access_token_validity  = lookup(each.value, "access_token_validity", null) != null ? lookup(each.value.access_token_validity, "value", 5) : 5
  id_token_validity      = lookup(each.value, "id_token_validity", null) != null ? lookup(each.value.id_token_validity, "value", 1) : 1
  refresh_token_validity = lookup(each.value, "refresh_token_validity", null) != null ? lookup(each.value.refresh_token_validity, "value", 30) : 30

  lifecycle {
    create_before_destroy = true
  }
}


# --- Secrets Manager per client ---
resource "aws_secretsmanager_secret" "apps" {
  for_each = aws_cognito_user_pool_client.apps
  name     = "ulng-m2m--secrets-internal-${var.env}-${each.key}"
}

resource "aws_secretsmanager_secret_version" "apps" {
  for_each = aws_cognito_user_pool_client.apps

  secret_id = aws_secretsmanager_secret.apps[each.key].id

  secret_string = jsonencode({
    clientid         = aws_cognito_user_pool_client.apps[each.key].client_id
    clientsecret     = aws_cognito_user_pool_client.apps[each.key].client_secret
    authorizedscopes = aws_cognito_user_pool_client.apps[each.key].allowed_oauth_scopes
  })
}
