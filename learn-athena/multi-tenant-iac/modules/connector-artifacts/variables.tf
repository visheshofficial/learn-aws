variable "name_prefix" {
  description = "Prefix for the three bucket names, which are suffixed with the account ID to stay globally unique."
  type        = string
  default     = "athena-fed"
}

variable "connector_version" {
  description = "aws-athena-query-federation release tag (without the leading 'v') to pull connector jars from."
  type        = string
  default     = "2026.24.1"
}

variable "spill_expiration_days" {
  description = "Days after which spilled query data is deleted. Spill data is transient scratch — there is no reason to retain it."
  type        = number
  default     = 1
}
