variable "name_prefix" {
  type    = string
  default = "athena-fed"
}

variable "vpc_id" {
  description = "VPC to place the endpoints and RDS subnet group in. Leave null to use the account's default VPC."
  type        = string
  default     = null
}
