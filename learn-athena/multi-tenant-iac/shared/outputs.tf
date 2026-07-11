output "aws_region" {
  value = local.region
}

output "aws_account_id" {
  value = local.account_id
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "rds_subnet_group_name" {
  value = aws_db_subnet_group.shared.name
}

output "code_bucket" {
  value = aws_s3_bucket.code.id
}

output "spill_bucket" {
  value = aws_s3_bucket.spill.id
}

output "results_bucket" {
  value = aws_s3_bucket.results.id
}

output "mysql_jar_key" {
  value = "connectors/${local.mysql_jar}"
}

output "dynamodb_catalog_name" {
  value = aws_athena_data_catalog.dynamodb.name
}

output "dynamodb_table_prefix" {
  value = var.dynamodb_table_prefix
}

output "connector_version" {
  value = var.connector_version
}

output "name_prefix" {
  value = var.name_prefix
}
