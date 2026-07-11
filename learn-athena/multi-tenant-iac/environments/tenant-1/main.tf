# A single tenant. Copy this directory to onboard another one — the only value
# that needs to change is tenant_id in terraform.tfvars.
#
# Everything shared comes in through remote state; nothing in this config writes
# to the shared stack, so applying or destroying a tenant never touches another
# tenant or the shared infrastructure.
#
# Module wiring, and why it is ordered this way:
#
#   tenant-network    ──> security groups (owns both, to break the cycle below)
#         │
#         ├─ rds_sg ──> tenant-datastores ──> RDS endpoint + secret ─┐
#         │                                                          │
#         └─ lambda_sg ─────────────────────> athena-connector <─────┘
#                                                    │
#                                                    └─> mysql catalog ──> tenant-access
#
# The cycle that tenant-network exists to break: the connector's env var needs
# the RDS endpoint, while the RDS security group needs the connector's security
# group. Owning the security groups in a third module makes the graph acyclic.

data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = var.shared_state_path
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs
}

module "network" {
  source = "../../modules/tenant-network"

  tenant_id = var.tenant_id
  vpc_id    = local.shared.vpc_id
}

module "datastores" {
  source = "../../modules/tenant-datastores"

  tenant_id             = var.tenant_id
  rds_subnet_group_name = local.shared.rds_subnet_group_name
  rds_security_group_id = module.network.rds_security_group_id
  dynamodb_table_prefix = local.shared.dynamodb_table_prefix
}

# This tenant's dedicated MySQL connector — the same athena-connector module the
# shared stack uses for DynamoDB, instantiated with the MySQL handler, the MySQL
# jar, a VPC attachment, and Secrets Manager permissions instead of DynamoDB ones.
data "aws_iam_policy_document" "mysql_connector" {
  statement {
    sid       = "ReadOwnSecretOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.datastores.mysql_secret_arn]
  }

  statement {
    sid       = "AthenaQueryStatus"
    effect    = "Allow"
    actions   = ["athena:GetQueryExecution"]
    resources = ["*"]
  }
}

module "mysql_connector" {
  source = "../../modules/athena-connector"

  name        = "athena_fed_tenant_${var.tenant_id}_mysql"
  description = "MySQL connector for tenant ${var.tenant_id}"

  # Mux handler, per the connector's own SAR template. It supports the
  # <catalog>_connection_string convention for serving multiple databases from
  # one Lambda; here only `default` is set, since this Lambda serves exactly one
  # tenant. See lambda-topology-options.md for why this is per-tenant rather
  # than one shared, multiplexed Lambda.
  handler    = "com.amazonaws.athena.connectors.mysql.MySqlMuxCompositeHandler"
  jar_s3_key = local.shared.mysql_jar_key

  code_bucket  = local.shared.code_bucket
  spill_bucket = local.shared.spill_bucket
  spill_prefix = "athena-spill/tenant-${var.tenant_id}"

  extra_environment_variables = {
    default = module.datastores.jdbc_connection_string
  }

  extra_policy_json = data.aws_iam_policy_document.mysql_connector.json

  # RDS is private, so the connector must be inside the VPC to reach it. This is
  # what makes the S3 and Secrets Manager VPC endpoints (in the shared stack)
  # mandatory rather than optional.
  vpc_config = {
    subnet_ids         = local.shared.subnet_ids
    security_group_ids = [module.network.lambda_security_group_id]
  }
}

module "access" {
  source = "../../modules/tenant-access"

  tenant_id      = var.tenant_id
  results_bucket = local.shared.results_bucket

  mysql_catalog_name    = module.mysql_connector.catalog_name
  dynamodb_catalog_name = local.shared.dynamodb_catalog_name
}
