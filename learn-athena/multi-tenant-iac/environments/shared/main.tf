# Shared environment — applied once, before any tenant.
#
# Owns everything that is not tenant-scoped: the S3 buckets, the connector jars,
# the VPC endpoints, and the single DynamoDB connector Lambda that serves every
# tenant's table.
#
# Nothing here changes when a tenant is added or removed. That is deliberate: it
# is what lets each tenant live in its own state file and be applied/destroyed
# independently.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "artifacts" {
  source = "../../modules/connector-artifacts"

  name_prefix       = var.name_prefix
  connector_version = var.connector_version
}

module "network" {
  source = "../../modules/federation-network"

  name_prefix = var.name_prefix
  vpc_id      = var.vpc_id
}

# The DynamoDB connector's data-source permissions.
#
# Scoped to the tenant_* table-name wildcard, so a new tenant's table is readable
# the moment it is created — no change to this stack required. The Glue and
# Athena actions cannot be scoped to a table ARN, so they are unavoidably "*".
#
# Note this is the one place where tenants genuinely share a data-plane identity:
# this single Lambda role can read every tenant's DynamoDB table. That is an
# accepted trade-off (DynamoDB has no connector multiplexing to build per-tenant
# routing on, and no per-tenant endpoint or credential to isolate), and it is
# documented in lambda-topology-options.md. Cross-tenant *querying* is still
# blocked by the per-tenant IAM in modules/tenant-access.
data "aws_iam_policy_document" "dynamodb_connector" {
  statement {
    sid    = "ReadTenantTables"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable", "dynamodb:ListTables",
      "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect",
    ]
    resources = [
      "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_prefix}*",
    ]
  }

  statement {
    sid    = "GlueAndAthenaMetadata"
    effect = "Allow"
    actions = [
      "glue:GetTableVersions", "glue:GetPartitions", "glue:GetTables", "glue:GetTableVersion",
      "glue:GetDatabases", "glue:GetTable", "glue:GetPartition", "glue:GetDatabase",
      "athena:GetQueryExecution",
    ]
    resources = ["*"]
  }
}

module "dynamodb_connector" {
  source = "../../modules/athena-connector"

  name        = "${replace(var.name_prefix, "-", "_")}_dynamodb"
  description = "Shared DynamoDB connector — serves every tenant's ${var.dynamodb_table_prefix}* table"

  handler    = "com.amazonaws.athena.connectors.dynamodb.DynamoDBCompositeHandler"
  jar_s3_key = module.artifacts.dynamodb_jar_key

  code_bucket  = module.artifacts.code_bucket
  spill_bucket = module.artifacts.spill_bucket
  spill_prefix = "athena-spill/dynamodb"

  extra_policy_json = data.aws_iam_policy_document.dynamodb_connector.json

  # No vpc_config: DynamoDB is a public AWS API, so this connector needs no VPC
  # attachment — and therefore no VPC endpoints, no ENIs, and no cold-start ENI
  # latency. Only the MySQL connectors are VPC-attached.

  # The jar is referenced by bucket/key strings, which Terraform cannot trace
  # back to the upload that creates it.
  depends_on = [module.artifacts]
}
