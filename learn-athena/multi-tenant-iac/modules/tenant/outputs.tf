output "dynamodb_table_name" {
  value = aws_dynamodb_table.this.name
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "mysql_secret_name" {
  value = aws_secretsmanager_secret.mysql.name
}

output "mysql_secret_arn" {
  value = aws_secretsmanager_secret.mysql.arn
}

output "mysql_catalog_name" {
  value = aws_athena_data_catalog.mysql.name
}

output "workgroup_name" {
  value = aws_athena_workgroup.this.name
}

output "query_role_arn" {
  description = "Assume this role (or grant your application's role permission to assume it) to query this tenant's data — it is IAM-restricted to this tenant's workgroup and catalogs only."
  value       = aws_iam_role.query.arn
}

output "mysql_database_name" {
  value = var.mysql_database_name
}
