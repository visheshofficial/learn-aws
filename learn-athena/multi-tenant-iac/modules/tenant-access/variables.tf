variable "tenant_id" {
  type = string
}

variable "results_bucket" {
  type = string
}

variable "mysql_catalog_name" {
  description = "This tenant's dedicated MySQL Athena Data Catalog."
  type        = string
}

variable "dynamodb_catalog_name" {
  description = "The shared DynamoDB Athena Data Catalog. Shared across tenants — isolation for DynamoDB comes from per-tenant table naming, not per-tenant catalogs."
  type        = string
}

variable "additional_catalog_names" {
  description = "Any further catalogs this tenant's query role may resolve — e.g. 'AwsDataCatalog' if the tenant also queries Glue-backed tables, or materializes dbt models."
  type        = list(string)
  default     = ["AwsDataCatalog"]
}

variable "assumable_by_arns" {
  description = "IAM principal ARNs permitted to assume this tenant's query role. Defaults to the account root, which delegates the decision to IAM identity policies within the account — fine for a demo, but replace it with the specific application/user role ARNs that represent this tenant before relying on it as a trust boundary."
  type        = list(string)
  default     = null
}
