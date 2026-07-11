data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  region         = data.aws_region.current.name
  dynamodb_jar   = "athena-dynamodb-${var.connector_version}.jar"
  mysql_jar      = "athena-mysql-${var.connector_version}.jar"
  code_bucket    = "${var.name_prefix}-code-${local.account_id}"
  spill_bucket   = "${var.name_prefix}-spill-${local.account_id}"
  results_bucket = "${var.name_prefix}-results-${local.account_id}"
}

# ---------------------------------------------------------------------------
# S3: connector code, Lambda spill, Athena query results — all shared across
# tenants. Each tenant gets its own prefix within spill/results (enforced via
# per-tenant IAM in modules/tenant), not its own bucket — spill data is
# transient scratch, and per-tenant IAM on a shared bucket prefix is
# sufficient isolation for both.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "code" {
  bucket = local.code_bucket
}

resource "aws_s3_bucket" "spill" {
  bucket = local.spill_bucket
}

resource "aws_s3_bucket_lifecycle_configuration" "spill" {
  bucket = aws_s3_bucket.spill.id
  rule {
    id     = "expire-spill-objects"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket" "results" {
  bucket = local.results_bucket
}

# Downloads the two connector jars from the GitHub release and uploads them to
# the code bucket. Requires `curl` and the `aws` CLI on the machine running
# `terraform apply` for this stack. Re-runs whenever connector_version changes.
resource "null_resource" "connector_jars" {
  triggers = {
    connector_version = var.connector_version
    code_bucket       = aws_s3_bucket.code.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      tmpdir=$(mktemp -d)
      curl -fL -o "$tmpdir/${local.dynamodb_jar}" \
        "https://github.com/awslabs/aws-athena-query-federation/releases/download/v${var.connector_version}/${local.dynamodb_jar}"
      curl -fL -o "$tmpdir/${local.mysql_jar}" \
        "https://github.com/awslabs/aws-athena-query-federation/releases/download/v${var.connector_version}/${local.mysql_jar}"
      aws s3 cp "$tmpdir/${local.dynamodb_jar}" "s3://${aws_s3_bucket.code.id}/connectors/${local.dynamodb_jar}" --region "${local.region}"
      aws s3 cp "$tmpdir/${local.mysql_jar}" "s3://${aws_s3_bucket.code.id}/connectors/${local.mysql_jar}" --region "${local.region}"
      rm -rf "$tmpdir"
    EOT
  }
}

# ---------------------------------------------------------------------------
# Networking shared by every tenant's MySQL Lambda + RDS instance, and by the
# shared DynamoDB Lambda. No NAT Gateway: an S3 Gateway endpoint (free) covers
# spill/code access, a Secrets Manager Interface endpoint covers credential
# fetches — same reasoning as the single-tenant setup, just shared once here
# instead of being per-tenant.
# ---------------------------------------------------------------------------

resource "aws_security_group" "secretsmanager_endpoint" {
  name        = "${var.name_prefix}-secretsmanager-endpoint-sg"
  description = "Secrets Manager VPC endpoint, shared by every tenant's MySQL connector Lambda"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTPS from anything in this VPC (tenant Lambdas each have their own SG, but all live in this one VPC)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids
}

data "aws_route_tables" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${local.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.secretsmanager_endpoint.id]
  private_dns_enabled = true
}

resource "aws_db_subnet_group" "shared" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

# ---------------------------------------------------------------------------
# DynamoDB connector — shared Lambda serving every tenant's table. Isolation
# choice made explicitly (not IAM-per-tenant): the DynamoDB connector has no
# per-catalog multiplexing, so real IAM isolation there would mean one Lambda
# per tenant. Instead, every tenant table is named "tenant_<id>_*" and this
# role's policy is scoped to that wildcard — cheaper, but any tenant's
# compromised Lambda invocation (there's only one) can technically read any
# tenant's table. MySQL isolation (see modules/tenant) does not make this
# trade-off — that's fully per-tenant.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dynamodb_lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dynamodb_lambda" {
  name               = "${var.name_prefix}-dynamodb-connector-role"
  assume_role_policy = data.aws_iam_policy_document.dynamodb_lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "dynamodb_lambda_basic" {
  role       = aws_iam_role.dynamodb_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "dynamodb_lambda_permissions" {
  statement {
    sid    = "DataSourceAndGlueAccess"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable", "dynamodb:ListTables", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect",
      "glue:GetTableVersions", "glue:GetPartitions", "glue:GetTables", "glue:GetTableVersion",
      "glue:GetDatabases", "glue:GetTable", "glue:GetPartition", "glue:GetDatabase",
      "athena:GetQueryExecution",
    ]
    resources = [
      "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.dynamodb_table_prefix}*",
      "*", # glue:* and athena:GetQueryExecution don't support resource-level scoping on a table ARN
    ]
  }
  statement {
    sid    = "SpillBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion",
      "s3:PutObject", "s3:PutObjectAcl", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration", "s3:DeleteObject",
    ]
    resources = [aws_s3_bucket.spill.arn, "${aws_s3_bucket.spill.arn}/*"]
  }
}

resource "aws_iam_role_policy" "dynamodb_lambda_permissions" {
  name   = "${var.name_prefix}-dynamodb-connector-permissions"
  role   = aws_iam_role.dynamodb_lambda.id
  policy = data.aws_iam_policy_document.dynamodb_lambda_permissions.json
}

resource "aws_lambda_function" "dynamodb_connector" {
  function_name = "${replace(var.name_prefix, "-", "_")}_dynamodb_connector"
  runtime       = "java21"
  role          = aws_iam_role.dynamodb_lambda.arn
  handler       = "com.amazonaws.athena.connectors.dynamodb.DynamoDBCompositeHandler"
  s3_bucket     = aws_s3_bucket.code.id
  s3_key        = "connectors/${local.dynamodb_jar}"
  memory_size   = 3008
  timeout       = 900

  environment {
    variables = {
      spill_bucket             = aws_s3_bucket.spill.id
      spill_prefix             = "athena-spill"
      disable_spill_encryption = "false"
      # Required on java21 — Arrow needs reflective access to java.nio.Buffer
      # internals that the JVM module system blocks by default. Without this,
      # every query fails inside the metadata handler and Athena reports it
      # back as a confusing TABLE_NOT_FOUND. Verified against the actual
      # CloudWatch stack trace during the single-tenant build of this same
      # connector — see athena-manual-connector-deployment.md.
      JAVA_TOOL_OPTIONS = "--add-opens=java.base/java.nio=ALL-UNNAMED"
    }
  }

  depends_on = [null_resource.connector_jars]
}

resource "aws_lambda_permission" "dynamodb_connector_athena" {
  statement_id  = "AllowAthenaInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dynamodb_connector.function_name
  principal     = "athena.amazonaws.com"
}

resource "aws_athena_data_catalog" "dynamodb" {
  name        = "${replace(var.name_prefix, "-", "_")}_dynamodb_catalog"
  type        = "LAMBDA"
  description = "Shared DynamoDB connector catalog — serves every tenant's tenant_<id>_* table"

  parameters = {
    function = aws_lambda_function.dynamodb_connector.arn
  }
}
