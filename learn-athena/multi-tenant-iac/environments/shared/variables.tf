variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  description = "Namespaces every shared resource within the account."
  type        = string
  default     = "athena-fed"
}

variable "connector_version" {
  description = "aws-athena-query-federation release to deploy connectors from."
  type        = string
  default     = "2026.24.1"
}

variable "vpc_id" {
  description = "Leave null to use the account's default VPC."
  type        = string
  default     = null
}

variable "dynamodb_table_prefix" {
  description = "Naming convention tenant DynamoDB tables must follow. The shared connector's IAM policy grants read access to exactly this prefix, so a tenant's table is queryable as soon as it is created."
  type        = string
  default     = "tenant_"
}
