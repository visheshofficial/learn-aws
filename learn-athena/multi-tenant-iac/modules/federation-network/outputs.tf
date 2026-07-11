output "vpc_id" {
  value = data.aws_vpc.selected.id
}

output "subnet_ids" {
  value = data.aws_subnets.selected.ids
}

output "rds_subnet_group_name" {
  value = aws_db_subnet_group.shared.name
}

output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "secretsmanager_endpoint_id" {
  value = aws_vpc_endpoint.secretsmanager.id
}
