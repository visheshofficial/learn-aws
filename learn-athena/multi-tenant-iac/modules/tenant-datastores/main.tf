# This tenant's actual data stores: a DynamoDB table and a dedicated RDS MySQL
# instance, plus the Secrets Manager secret holding the DB's master credentials.
#
# The DynamoDB table is named with the shared prefix (tenant_<id>_*) because the
# shared DynamoDB connector Lambda's IAM policy grants access by that wildcard —
# creating the table here is all that is needed to make it queryable; nothing in
# the shared stack has to change when a tenant is added.
#
# The RDS instance is dedicated per tenant and private (no public access). Its
# security group, passed in from modules/tenant-network, admits only this
# tenant's connector Lambda.

resource "aws_dynamodb_table" "this" {
  name         = "${var.dynamodb_table_prefix}${var.tenant_id}_${var.dynamodb_table_name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "customer_id"

  attribute {
    name = "customer_id"
    type = "S"
  }
}

# Resolves the newest available MySQL 8.0 engine version at plan time rather than
# pinning a version that will eventually be deprecated out from under this code.
data "aws_rds_engine_version" "mysql" {
  engine  = "mysql"
  version = var.mysql_major_version
  latest  = true
}

resource "random_password" "mysql_master" {
  length = 20
  # Alphanumeric only. The password never appears in the JDBC URL (the connector
  # injects it as a separate connection property, see GenericJdbcConnectionFactory),
  # but keeping it URL-safe avoids a class of escaping bugs if it is ever pasted
  # into a connection string by hand.
  special = false
}

resource "aws_db_instance" "this" {
  identifier     = "athena-fed-tenant-${var.tenant_id}-mysql"
  engine         = "mysql"
  engine_version = data.aws_rds_engine_version.mysql.version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.mysql_database_name
  username = var.mysql_master_username
  password = random_password.mysql_master.result

  db_subnet_group_name   = var.rds_subnet_group_name
  vpc_security_group_ids = [var.rds_security_group_id]
  publicly_accessible    = false

  # Demo posture: no backups, no final snapshot, destroy cleanly. Revisit all
  # three before anything resembling production.
  backup_retention_period = var.rds_backup_retention_days
  multi_az                = false
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
}

resource "aws_secretsmanager_secret" "mysql" {
  name                    = "athena-fed-tenant-${var.tenant_id}-mysql"
  recovery_window_in_days = var.secret_recovery_window_days
}

# The connector requires exactly these two JSON keys — verified in
# DefaultCredentialsProvider.java, which reads "username" and "password" and
# ignores everything else.
resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = aws_db_instance.this.username
    password = random_password.mysql_master.result
  })
}
