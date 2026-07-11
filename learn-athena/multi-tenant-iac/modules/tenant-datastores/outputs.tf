output "dynamodb_table_name" {
  value = aws_dynamodb_table.this.name
}

output "rds_instance_id" {
  value = aws_db_instance.this.identifier
}

output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "mysql_database_name" {
  value = var.mysql_database_name
}

output "mysql_secret_name" {
  value = aws_secretsmanager_secret.mysql.name
}

output "mysql_secret_arn" {
  value = aws_secretsmanager_secret.mysql.arn
}

# The connector resolves ${SecretName} at invocation time by calling Secrets
# Manager — the literal token stays in the env var, and the password is never
# embedded in the connection string. Verified in GenericJdbcConnectionFactory:
# the ${...} token is stripped from the URL and credentials are injected as
# separate JDBC properties.
output "jdbc_connection_string" {
  value = "mysql://jdbc:mysql://${aws_db_instance.this.address}:3306/${var.mysql_database_name}?$${${aws_secretsmanager_secret.mysql.name}}"
}
