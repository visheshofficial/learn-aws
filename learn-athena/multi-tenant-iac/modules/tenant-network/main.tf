# This tenant's two security groups, and nothing else.
#
# These live in their own module to break what would otherwise be a dependency
# cycle between the connector and the database:
#
#   the MySQL Lambda's env var needs the RDS endpoint   (connector -> datastore)
#   the RDS security group's ingress rule needs the Lambda's SG (datastore -> connector)
#
# Owning the security groups here, and passing their IDs into both of the other
# modules, keeps the graph acyclic. Terraform rejects module cycles outright, so
# this is structural, not stylistic.
#
# This pair of security groups is the tenant's data-plane isolation boundary:
# only this tenant's Lambda SG is permitted into this tenant's RDS instance, so
# another tenant's connector has no network path here even if its IAM were
# somehow wrong.

resource "aws_security_group" "lambda" {
  name        = "athena-fed-tenant-${var.tenant_id}-lambda-sg"
  description = "MySQL connector Lambda for tenant ${var.tenant_id}. No inbound rules — Lambda never receives inbound traffic; it only makes outbound calls to RDS, S3, and Secrets Manager."
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "rds" {
  name        = "athena-fed-tenant-${var.tenant_id}-rds-sg"
  description = "RDS MySQL for tenant ${var.tenant_id}"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL, from this tenant's connector Lambda only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}
