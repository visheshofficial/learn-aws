# The only value that must change when you copy this directory for a new tenant.
variable "tenant_id" {
  description = "Short, unique tenant identifier."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,20}$", var.tenant_id))
    error_message = "tenant_id must be 2-20 lowercase alphanumeric characters. No hyphens or underscores: this string is embedded in DynamoDB table names, RDS identifiers, Lambda function names, and Athena catalog names, whose character restrictions do not all overlap."
  }
}

# Must match the shared stack's region.
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Only change if you moved the shared environment.
variable "shared_state_path" {
  type    = string
  default = "../shared/terraform.tfstate"
}
