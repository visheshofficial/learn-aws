output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "catalog_name" {
  value = aws_athena_data_catalog.this.name
}

output "catalog_arn" {
  value = aws_athena_data_catalog.this.arn
}
