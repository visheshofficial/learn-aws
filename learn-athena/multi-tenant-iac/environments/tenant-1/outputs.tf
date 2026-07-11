output "dynamodb_table_name" {
  value = module.datastores.dynamodb_table_name
}

output "rds_instance_id" {
  value = module.datastores.rds_instance_id
}

output "rds_endpoint" {
  value = module.datastores.rds_endpoint
}

output "mysql_database_name" {
  value = module.datastores.mysql_database_name
}

output "mysql_secret_name" {
  value = module.datastores.mysql_secret_name
}

output "mysql_catalog_name" {
  value = module.mysql_connector.catalog_name
}

output "mysql_connector_function_name" {
  value = module.mysql_connector.function_name
}

output "rds_security_group_id" {
  description = "Needed when temporarily opening RDS to your IP to seed data."
  value       = module.network.rds_security_group_id
}

output "workgroup_name" {
  value = module.access.workgroup_name
}

output "query_role_arn" {
  value = module.access.query_role_arn
}
