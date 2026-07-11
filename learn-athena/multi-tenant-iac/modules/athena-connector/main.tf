# Generic Athena federation connector: IAM role, Lambda, Athena invoke
# permission, and the Athena Data Catalog that fronts it.
#
# Instantiated twice in this repo — once for the shared DynamoDB connector
# (no VPC), once per tenant for MySQL (VPC-attached). Everything that differs
# between the two is an input: handler class, jar, env vars, IAM statements,
# and whether a vpc_config is supplied.

locals {
  is_vpc_attached = var.vpc_config != null

  base_environment_variables = {
    spill_bucket             = var.spill_bucket
    spill_prefix             = var.spill_prefix
    disable_spill_encryption = "false"

    # Required on the java21 runtime. The federation SDK uses Apache Arrow,
    # which needs reflective access to java.nio.Buffer internals that the JVM
    # module system blocks by default on Java 17+. Without this the connector
    # crashes inside its metadata handler with
    # "InaccessibleObjectException: Unable to make field long java.nio.Buffer.address accessible",
    # which Athena surfaces to the user as a misleading TABLE_NOT_FOUND.
    JAVA_TOOL_OPTIONS = "--add-opens=java.base/java.nio=ALL-UNNAMED"
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}_role"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# A VPC-attached Lambda needs ec2:CreateNetworkInterface/DeleteNetworkInterface/
# DescribeNetworkInterfaces to start up at all, which only the VPC-access managed
# policy grants. A non-VPC Lambda only needs CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "execution" {
  role = aws_iam_role.this.name
  policy_arn = (local.is_vpc_attached
    ? "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
    : "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  )
}

# Spill-bucket access, scoped to this connector's own spill prefix. Every
# connector needs this; the data-source-specific half comes in via
# extra_policy_json.
data "aws_iam_policy_document" "spill" {
  statement {
    sid    = "SpillObjectsUnderOwnPrefixOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:PutObjectAcl",
      "s3:DeleteObject", "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
    ]
    resources = ["arn:aws:s3:::${var.spill_bucket}/${var.spill_prefix}/*"]
  }
  statement {
    sid       = "ListOwnSpillPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.spill_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.spill_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "spill" {
  name   = "${var.name}_spill"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.spill.json
}

resource "aws_iam_role_policy" "data_source" {
  name   = "${var.name}_data_source"
  role   = aws_iam_role.this.id
  policy = var.extra_policy_json
}

resource "aws_lambda_function" "this" {
  function_name = var.name
  description   = var.description
  runtime       = "java21"
  role          = aws_iam_role.this.arn
  handler       = var.handler
  s3_bucket     = var.code_bucket
  s3_key        = var.jar_s3_key
  memory_size   = var.memory_size
  timeout       = var.timeout

  dynamic "vpc_config" {
    for_each = local.is_vpc_attached ? [var.vpc_config] : []
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  environment {
    variables = merge(local.base_environment_variables, var.extra_environment_variables)
  }

  # The role's policies must land before the function is created, or Lambda
  # rejects the role. Ordering on the jar upload itself is the caller's job:
  # pass `depends_on = [module.connector_artifacts]` at the module call site,
  # since the jar is referenced only by bucket/key strings that Terraform
  # cannot trace back to the upload.
  depends_on = [
    aws_iam_role_policy.spill,
    aws_iam_role_policy.data_source,
    aws_iam_role_policy_attachment.execution,
  ]
}

resource "aws_lambda_permission" "athena" {
  statement_id  = "AllowAthenaInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "athena.amazonaws.com"
}

resource "aws_athena_data_catalog" "this" {
  name        = "${var.name}_catalog"
  type        = "LAMBDA"
  description = var.description

  parameters = {
    function = aws_lambda_function.this.arn
  }
}
