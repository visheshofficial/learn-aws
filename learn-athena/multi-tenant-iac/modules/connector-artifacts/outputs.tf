output "code_bucket" {
  value = aws_s3_bucket.code.id
}

output "spill_bucket" {
  value = aws_s3_bucket.spill.id
}

output "results_bucket" {
  value = aws_s3_bucket.results.id
}

output "dynamodb_jar_key" {
  value = "connectors/${local.dynamodb_jar}"
}

output "mysql_jar_key" {
  value = "connectors/${local.mysql_jar}"
}

output "connector_version" {
  value = var.connector_version
}
