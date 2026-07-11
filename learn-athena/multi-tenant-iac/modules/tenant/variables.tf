# --- Required: identifies the tenant, everything else is named from this ---

variable "tenant_id" {
  description = "Short, unique tenant identifier. Used to derive every resource name (DynamoDB table, RDS instance, Lambda, Secrets Manager secret, Athena catalog/workgroup)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,20}$", var.tenant_id))
    error_message = "tenant_id must be 2-20 lowercase alphanumeric characters (no hyphens/underscores — it gets embedded in DynamoDB table names, RDS identifiers, and Athena catalog names, which have different, overlapping character restrictions)."
  }
}

# --- Wired in from shared/ state by the calling root config — not meant to
#     be hand-typed per tenant, but still plain module variables so this
#     module has no implicit coupling to *how* the caller looked them up.

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "rds_subnet_group_name" {
  type = string
}

variable "code_bucket" {
  type = string
}

variable "spill_bucket" {
  type = string
}

variable "results_bucket" {
  type = string
}

variable "mysql_jar_key" {
  description = "S3 key of the MySQL connector jar within code_bucket."
  type        = string
}

variable "dynamodb_catalog_name" {
  description = "Name of the shared DynamoDB Athena Data Catalog (all tenants query the same one — see shared/main.tf for why)."
  type        = string
}

variable "dynamodb_table_prefix" {
  description = "Must match shared/variables.tf's dynamodb_table_prefix — the shared connector Lambda's IAM policy only grants access to tables under this prefix."
  type        = string
  default     = "tenant_"
}

# --- Optional, rarely-touched overrides — sensible defaults for everything ---

variable "dynamodb_table_name" {
  description = "Logical table name suffix. Actual table becomes '<dynamodb_table_prefix><tenant_id>_<this>'."
  type        = string
  default     = "customers"
}

variable "mysql_database_name" {
  type    = string
  default = "app_db"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "lambda_memory_size" {
  type    = number
  default = 3008
}

variable "lambda_timeout" {
  type    = number
  default = 900
}

variable "assumable_by_arns" {
  description = "IAM principal ARNs allowed to assume this tenant's query role (the role scoped to only this tenant's Athena workgroup + catalog). Defaults to the account root, which just means \"any IAM principal in this account with sts:AssumeRole permission on this role's ARN can assume it\" — override with the specific application/user role ARN(s) that should represent this tenant in a real deployment."
  type        = list(string)
  default     = null
}
