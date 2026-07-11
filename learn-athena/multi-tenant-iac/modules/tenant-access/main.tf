# This tenant's query-time boundary: an Athena workgroup and an IAM role scoped
# to it.
#
# This is the control-plane half of tenant isolation, and it holds regardless of
# how the connector Lambdas are deployed. Athena supports resource-level IAM on
# both `datacatalog` and `workgroup` ARNs, so this role can be restricted to
# "only resolve metadata for these catalogs, only run queries in this workgroup".
# A caller holding this role cannot get Athena to route a query at another
# tenant's catalog — the GetDataCatalog/GetTableMetadata call is denied before a
# connector Lambda is ever invoked.
#
# The data-plane half (per-tenant Lambda, RDS, and security groups) is enforced
# separately. The two are defense in depth, not alternatives.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Every tenant shares the results bucket but is confined to its own prefix,
  # enforced by the IAM policy below rather than by separate buckets.
  results_prefix = "tenant-${var.tenant_id}"

  assumable_by = coalesce(var.assumable_by_arns, ["arn:aws:iam::${local.account_id}:root"])

  catalog_arns = [
    for name in concat([var.mysql_catalog_name, var.dynamodb_catalog_name], var.additional_catalog_names) :
    "arn:aws:athena:${local.region}:${local.account_id}:datacatalog/${name}"
  ]
}

resource "aws_athena_workgroup" "this" {
  name          = "tenant_${var.tenant_id}_workgroup"
  force_destroy = true

  configuration {
    # Prevents a caller from overriding the result location and writing this
    # tenant's query output somewhere outside its own prefix.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # Pinned explicitly rather than inheriting the account default. Engine v3 is
    # Athena's current, Trino-based engine.
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.results_bucket}/${local.results_prefix}/"
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = local.assumable_by
    }
  }
}

resource "aws_iam_role" "query" {
  name               = "athena-fed-tenant-${var.tenant_id}-query-role"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "query" {
  statement {
    sid    = "RunQueriesInOwnWorkgroupOnly"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution", "athena:StopQueryExecution",
      "athena:GetQueryExecution", "athena:GetQueryResults", "athena:GetQueryRuntimeStatistics",
      "athena:GetWorkGroup", "athena:ListQueryExecutions",
    ]
    resources = [aws_athena_workgroup.this.arn]
  }

  statement {
    sid    = "ResolveOwnCatalogsOnly"
    effect = "Allow"
    actions = [
      "athena:GetDataCatalog", "athena:GetDatabase", "athena:GetTableMetadata",
      "athena:ListDatabases", "athena:ListTableMetadata",
    ]
    resources = local.catalog_arns
  }

  # Athena needs this to enumerate catalogs at all; it cannot be scoped to a
  # resource. It leaks only catalog *names*, not their contents — resolving any
  # metadata within them is still gated by the statement above.
  statement {
    sid       = "ListCatalogNames"
    effect    = "Allow"
    actions   = ["athena:ListDataCatalogs", "athena:ListWorkGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadWriteOwnQueryResultsOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["arn:aws:s3:::${var.results_bucket}/${local.results_prefix}/*"]
  }

  statement {
    sid       = "ListOwnResultsPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.results_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.results_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "query" {
  name   = "athena-fed-tenant-${var.tenant_id}-query"
  role   = aws_iam_role.query.id
  policy = data.aws_iam_policy_document.query.json
}
