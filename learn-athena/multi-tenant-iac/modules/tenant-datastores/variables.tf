variable "tenant_id" {
  type = string
}

variable "rds_subnet_group_name" {
  type = string
}

variable "rds_security_group_id" {
  description = "From modules/tenant-network — the SG that admits only this tenant's connector Lambda."
  type        = string
}

variable "dynamodb_table_prefix" {
  description = "Must match the prefix the shared DynamoDB connector's IAM policy is scoped to, or the connector will not be able to read this table."
  type        = string
  default     = "tenant_"
}

variable "dynamodb_table_name" {
  description = "Logical name; the actual table becomes '<dynamodb_table_prefix><tenant_id>_<this>'."
  type        = string
  default     = "customers"
}

variable "mysql_database_name" {
  type    = string
  default = "app_db"
}

variable "mysql_master_username" {
  type    = string
  default = "admin"
}

variable "mysql_major_version" {
  description = "Major version to pin to; the exact minor version is resolved to the latest available at plan time."
  type        = string
  default     = "8.0"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "rds_backup_retention_days" {
  description = "0 disables automated backups, which keeps teardown clean. Raise this for anything real."
  type        = number
  default     = 0
}

variable "secret_recovery_window_days" {
  description = "0 force-deletes the secret immediately on destroy instead of holding it for a 7-30 day recovery window — which would otherwise block re-creating a tenant with the same id."
  type        = number
  default     = 0
}
