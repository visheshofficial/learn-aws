output "workgroup_name" {
  value = aws_athena_workgroup.this.name
}

output "workgroup_arn" {
  value = aws_athena_workgroup.this.arn
}

output "query_role_arn" {
  description = "Assume this role to query as this tenant. It is IAM-restricted to this tenant's workgroup and catalogs — use it, rather than admin credentials, if you want to actually exercise the isolation boundary."
  value       = aws_iam_role.query.arn
}

output "results_prefix" {
  value = local.results_prefix
}
