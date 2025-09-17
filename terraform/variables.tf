variable "env" {
  type        = string
  description = "Environment: dev|stg|prod"
}

variable "region" {
  type    = string
  default = "us-east-2"
}
