variable "name" {
  description = "Base name for the Lambda function, IAM role, and Athena Data Catalog. Must satisfy the Lambda function name pattern; the catalog name additionally may not contain hyphens, so use underscores."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9_]{1,64}$", var.name))
    error_message = "name must be lowercase alphanumeric or underscore (no hyphens — Athena Data Catalog names reject them)."
  }
}

variable "description" {
  description = "Human-readable description, applied to both the Lambda and the Athena Data Catalog."
  type        = string
  default     = "Athena federation connector"
}

variable "handler" {
  description = "Fully-qualified connector handler class. NOT 'ProxyHandler' — that class does not exist in the connector repo. Use e.g. com.amazonaws.athena.connectors.dynamodb.DynamoDBCompositeHandler or com.amazonaws.athena.connectors.mysql.MySqlMuxCompositeHandler."
  type        = string
}

variable "code_bucket" {
  description = "S3 bucket holding the connector jar."
  type        = string
}

variable "jar_s3_key" {
  description = "S3 key of the connector jar within code_bucket."
  type        = string
}

variable "spill_bucket" {
  description = "S3 bucket the connector spills oversized result batches into."
  type        = string
}

variable "spill_prefix" {
  description = "Prefix within spill_bucket. Scope this per tenant (e.g. athena-spill/tenant-acme) so the IAM policy below can restrict the connector to its own spill objects."
  type        = string
  default     = "athena-spill"
}

variable "extra_environment_variables" {
  description = "Connector-specific env vars merged into the base set. The MySQL connector needs a 'default' connection string here; the DynamoDB connector needs nothing."
  type        = map(string)
  default     = {}
}

variable "extra_policy_json" {
  description = "JSON of an IAM policy document with the connector's data-source-specific permissions (DynamoDB read + Glue, or Secrets Manager read). Merged with the spill-bucket permissions this module always grants."
  type        = string
}

variable "vpc_config" {
  description = "Set to attach the Lambda to a VPC — required for connectors reaching a private data source like RDS. Leave null for connectors hitting a public AWS API (DynamoDB), which need no VPC at all. When set, the module attaches AWSLambdaVPCAccessExecutionRole instead of AWSLambdaBasicExecutionRole, since a VPC-attached Lambda needs ENI management permissions to start at all."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "memory_size" {
  type    = number
  default = 3008
}

variable "timeout" {
  type    = number
  default = 900
}
