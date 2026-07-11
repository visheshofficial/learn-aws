# S3 buckets that every connector and every tenant share, plus the connector
# jars themselves, fetched from the aws-athena-query-federation GitHub release
# and uploaded to the code bucket.
#
# Tenants share these buckets but are confined to their own prefixes within
# them, enforced by per-tenant IAM (see modules/athena-connector's spill policy
# and modules/tenant-access's results policy) rather than by separate buckets.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  dynamodb_jar = "athena-dynamodb-${var.connector_version}.jar"
  mysql_jar    = "athena-mysql-${var.connector_version}.jar"
}

resource "aws_s3_bucket" "code" {
  bucket = "${var.name_prefix}-code-${local.account_id}"
}

resource "aws_s3_bucket" "spill" {
  bucket = "${var.name_prefix}-spill-${local.account_id}"
}

# Spilled data is transient scratch — expire it rather than paying to store it.
resource "aws_s3_bucket_lifecycle_configuration" "spill" {
  bucket = aws_s3_bucket.spill.id

  rule {
    id     = "expire-spill-objects"
    status = "Enabled"
    filter {}
    expiration {
      days = var.spill_expiration_days
    }
  }
}

resource "aws_s3_bucket" "results" {
  bucket = "${var.name_prefix}-results-${local.account_id}"
}

# Fetches both connector jars and uploads them. Requires curl and the aws CLI on
# whatever machine runs `terraform apply`. Re-runs when connector_version changes.
#
# For a real pipeline, do this in CI (fetch, checksum, upload) before Terraform
# runs, so `apply` doesn't depend on GitHub being reachable.
resource "null_resource" "connector_jars" {
  triggers = {
    connector_version = var.connector_version
    code_bucket       = aws_s3_bucket.code.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' EXIT
      for jar in "${local.dynamodb_jar}" "${local.mysql_jar}"; do
        curl -fL -o "$tmpdir/$jar" \
          "https://github.com/awslabs/aws-athena-query-federation/releases/download/v${var.connector_version}/$jar"
        aws s3 cp "$tmpdir/$jar" "s3://${aws_s3_bucket.code.id}/connectors/$jar" --region "${local.region}"
      done
    EOT
  }
}
