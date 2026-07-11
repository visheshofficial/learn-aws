output "dynamodb_table_name" {
  value = module.tenant.dynamodb_table_name
}

output "rds_endpoint" {
  value = module.tenant.rds_endpoint
}

output "mysql_secret_name" {
  value = module.tenant.mysql_secret_name
}

output "mysql_catalog_name" {
  value = module.tenant.mysql_catalog_name
}

output "workgroup_name" {
  value = module.tenant.workgroup_name
}

output "query_role_arn" {
  value = module.tenant.query_role_arn
}

output "mysql_database_name" {
  value = module.tenant.mysql_database_name
}
