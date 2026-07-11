# Consumed by every tenant environment via terraform_remote_state.

output "aws_region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "subnet_ids" {
  value = module.network.subnet_ids
}

output "rds_subnet_group_name" {
  value = module.network.rds_subnet_group_name
}

output "code_bucket" {
  value = module.artifacts.code_bucket
}

output "spill_bucket" {
  value = module.artifacts.spill_bucket
}

output "results_bucket" {
  value = module.artifacts.results_bucket
}

output "mysql_jar_key" {
  value = module.artifacts.mysql_jar_key
}

output "dynamodb_catalog_name" {
  value = module.dynamodb_connector.catalog_name
}

output "dynamodb_connector_function_name" {
  value = module.dynamodb_connector.function_name
}

output "dynamodb_table_prefix" {
  value = var.dynamodb_table_prefix
}
