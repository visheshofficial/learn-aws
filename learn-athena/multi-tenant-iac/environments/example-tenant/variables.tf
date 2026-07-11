# This is the only variable you actually need to set per tenant. Copy this
# whole directory to environments/<new-tenant>/ and change tenant_id (and the
# directory name, for your own sanity) — that's the entire onboarding step.
variable "tenant_id" {
  description = "Short, unique tenant identifier (2-20 lowercase alphanumeric characters)."
  type        = string
}

# Must match shared/variables.tf's aws_region — only exposed here because the
# provider block needs it before any data/state lookup can happen.
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Only override this if you renamed/moved the shared/ directory.
variable "shared_state_path" {
  type    = string
  default = "../../shared/terraform.tfstate"
}
