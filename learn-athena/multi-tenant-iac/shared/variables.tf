variable "aws_region" {
  description = "AWS region for every resource this stack creates."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to every shared resource name, to namespace this stack within the account."
  type        = string
  default     = "athena-fed"
}

variable "connector_version" {
  description = "aws-athena-query-federation release tag to pull connector jars from."
  type        = string
  default     = "2026.24.1"
}

variable "dynamodb_table_prefix" {
  description = "Naming convention every tenant DynamoDB table must follow. The shared connector Lambda's IAM policy grants read access to exactly this prefix (wildcarded) — changing it here and in modules/tenant must be done together."
  type        = string
  default     = "tenant_"
}
