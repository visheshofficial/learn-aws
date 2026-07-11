data "aws_caller_identity" "current" {}
data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  t                 = var.tenant_id
  account_id        = data.aws_caller_identity.current.account_id
  dynamodb_table    = "${var.dynamodb_table_prefix}${local.t}_${var.dynamodb_table_name}"
  secret_name       = "athena-fed-tenant-${local.t}-mysql"
  spill_prefix      = "athena-spill/tenant-${local.t}"
  results_prefix    = "tenant-${local.t}"
  mysql_catalog     = "mysql_catalog_${local.t}"
  workgroup_name    = "tenant_${local.t}_workgroup"
  assumable_by_arns = coalesce(var.assumable_by_arns, ["arn:aws:iam::${local.account_id}:root"])
}

# ---------------------------------------------------------------------------
# DynamoDB — this tenant's table only. Covered automatically by the shared
# connector Lambda's wildcard IAM policy because of the tenant_<id>_ prefix;
# nothing here needs to touch the shared stack's state.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "this" {
  name         = local.dynamodb_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "customer_id"

  attribute {
    name = "customer_id"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# Networking — this tenant's own security groups. Nothing shared with other
# tenants beyond the VPC/subnets/Secrets Manager endpoint themselves, which
# are pure network plumbing, not data access.
# ---------------------------------------------------------------------------

resource "aws_security_group" "lambda" {
  name        = "athena-fed-tenant-${local.t}-lambda-sg"
  description = "MySQL connector Lambda for tenant ${local.t} — no inbound rules, Lambda never receives inbound traffic"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "rds" {
  name        = "athena-fed-tenant-${local.t}-rds-sg"
  description = "RDS MySQL for tenant ${local.t} — 3306 only from this tenant's own Lambda SG"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from this tenant's connector Lambda only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

# ---------------------------------------------------------------------------
# RDS — dedicated instance per tenant. Full storage/compute/network isolation;
# no other tenant's Lambda has a security-group path to this instance.
# ---------------------------------------------------------------------------

data "aws_rds_engine_version" "mysql" {
  engine = "mysql"
  latest = true
}

resource "random_password" "mysql_master" {
  length  = 20
  special = false # keep it URL-safe; it never appears in the JDBC URL itself anyway, only in the Secrets Manager JSON
}

resource "aws_db_instance" "this" {
  identifier     = "athena-fed-tenant-${local.t}-mysql"
  engine         = "mysql"
  engine_version = data.aws_rds_engine_version.mysql.version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true
  db_name           = var.mysql_database_name
  username          = "admin"
  password          = random_password.mysql_master.result

  db_subnet_group_name   = var.rds_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 0
  multi_az                = false
  publicly_accessible     = false
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
}

resource "aws_secretsmanager_secret" "mysql" {
  name = local.secret_name
}

resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = aws_db_instance.this.username
    password = random_password.mysql_master.result
  })
}

# ---------------------------------------------------------------------------
# MySQL connector Lambda — dedicated per tenant. Its IAM role can only reach
# this tenant's secret and this tenant's spill-bucket prefix; its security
# group is only ever allowed into this tenant's RDS instance. Even a total
# compromise of this Lambda cannot reach any other tenant's data.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "athena-fed-tenant-${local.t}-mysql-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid       = "ThisTenantsSecretOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.mysql.arn]
  }
  statement {
    sid       = "AthenaInvoke"
    effect    = "Allow"
    actions   = ["athena:GetQueryExecution"]
    resources = ["*"]
  }
  statement {
    sid       = "SpillObjectsUnderThisTenantsPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectVersion", "s3:PutObjectAcl", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration"]
    resources = ["arn:aws:s3:::${var.spill_bucket}/${local.spill_prefix}/*"]
  }
  statement {
    sid       = "ListBucketScopedToThisTenantsPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.spill_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.spill_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "athena-fed-tenant-${local.t}-mysql-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_lambda_function" "mysql_connector" {
  function_name = "athena_fed_tenant_${local.t}_mysql_connector"
  runtime       = "java21"
  role          = aws_iam_role.lambda.arn
  handler       = "com.amazonaws.athena.connectors.mysql.MySqlMuxCompositeHandler"
  s3_bucket     = var.code_bucket
  s3_key        = var.mysql_jar_key
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      spill_bucket             = var.spill_bucket
      spill_prefix             = local.spill_prefix
      disable_spill_encryption = "false"
      default                  = "mysql://jdbc:mysql://${aws_db_instance.this.address}:3306/${var.mysql_database_name}?$${${aws_secretsmanager_secret.mysql.name}}"
      JAVA_TOOL_OPTIONS        = "--add-opens=java.base/java.nio=ALL-UNNAMED"
    }
  }
}

resource "aws_lambda_permission" "mysql_connector_athena" {
  statement_id  = "AllowAthenaInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mysql_connector.function_name
  principal     = "athena.amazonaws.com"
}

resource "aws_athena_data_catalog" "mysql" {
  name        = local.mysql_catalog
  type        = "LAMBDA"
  description = "Dedicated MySQL connector catalog for tenant ${local.t}"

  parameters = {
    function = aws_lambda_function.mysql_connector.arn
  }
}

# ---------------------------------------------------------------------------
# Athena workgroup — forces engine v3 (Trino-based) and gives this tenant its
# own query-execution boundary + its own result-location prefix. Combined
# with the IAM role below, this is the second, independent isolation layer:
# even with a shared DynamoDB Lambda, a caller restricted to this workgroup +
# these catalog ARNs cannot get Athena to resolve another tenant's MySQL
# catalog, because GetDataCatalog/GetTableMetadata on that ARN would be denied
# before the query ever reaches a connector Lambda.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "this" {
  name = local.workgroup_name

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.results_bucket}/${local.results_prefix}/"
    }
  }
}

data "aws_iam_policy_document" "query_role_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = local.assumable_by_arns
    }
  }
}

resource "aws_iam_role" "query" {
  name               = "athena-fed-tenant-${local.t}-query-role"
  assume_role_policy = data.aws_iam_policy_document.query_role_trust.json
}

data "aws_iam_policy_document" "query_role_permissions" {
  statement {
    sid    = "RunQueriesInThisWorkgroupOnly"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
      "athena:StopQueryExecution", "athena:GetWorkGroup", "athena:ListQueryExecutions",
    ]
    resources = [aws_athena_workgroup.this.arn]
  }
  statement {
    sid    = "ResolveThisTenantsCatalogsOnly"
    effect = "Allow"
    actions = [
      "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
      "athena:ListDatabases", "athena:ListTableMetadata",
    ]
    resources = [
      aws_athena_data_catalog.mysql.arn,
      "arn:aws:athena:${var.aws_region}:${local.account_id}:datacatalog/${var.dynamodb_catalog_name}",
      "arn:aws:athena:${var.aws_region}:${local.account_id}:datacatalog/AwsDataCatalog",
    ]
  }
  statement {
    sid       = "ReadOwnQueryResultsOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.results_bucket}", "arn:aws:s3:::${var.results_bucket}/${local.results_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "query_role_permissions" {
  name   = "athena-fed-tenant-${local.t}-query-permissions"
  role   = aws_iam_role.query.id
  policy = data.aws_iam_policy_document.query_role_permissions.json
}
