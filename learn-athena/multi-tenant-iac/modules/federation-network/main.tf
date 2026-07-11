# VPC plumbing shared by every tenant's MySQL connector Lambda and RDS instance.
#
# Why the two VPC endpoints are mandatory, not optional: a VPC-attached Lambda
# has no default route to the internet or to public AWS API endpoints. The MySQL
# connector must reach S3 (to spill) and Secrets Manager (to fetch DB
# credentials, a synchronous call it cannot proceed without). Rather than pay for
# a NAT Gateway, an S3 Gateway endpoint (free) and a Secrets Manager Interface
# endpoint cover exactly those two needs.
#
# CloudWatch Logs needs no endpoint — Lambda ships logs via its control plane,
# not through the VPC ENI. The connector's own athena:GetQueryExecution call is
# best-effort (see QueryStatusChecker.java — it catches and logs failures rather
# than aborting), so no Athena endpoint is needed either.
#
# Sharing this network across tenants does not weaken tenant isolation: it is
# routing, not data access. Isolation is enforced by per-tenant security groups
# (modules/tenant-network) and per-tenant IAM, not by separate VPCs.

data "aws_region" "current" {}

data "aws_vpc" "selected" {
  id      = var.vpc_id
  default = var.vpc_id == null ? true : null
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_route_tables" "selected" {
  vpc_id = data.aws_vpc.selected.id
}

resource "aws_security_group" "secretsmanager_endpoint" {
  name        = "${var.name_prefix}-secretsmanager-endpoint-sg"
  description = "Secrets Manager VPC endpoint — accepts HTTPS from tenant connector Lambdas in this VPC"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "HTTPS from within this VPC. Each tenant Lambda has its own SG, but all live in this VPC; the endpoint itself exposes no tenant data, it only proxies Secrets Manager API calls that are separately authorized by each Lambda's IAM role."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.selected.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.selected.ids
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.selected.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.selected.ids
  security_group_ids  = [aws_security_group.secretsmanager_endpoint.id]
  private_dns_enabled = true
}

# Shared across tenants — a subnet group only declares which subnets RDS may
# place instances in. Each tenant still gets its own instance, with its own
# security group.
resource "aws_db_subnet_group" "shared" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = data.aws_subnets.selected.ids
}
