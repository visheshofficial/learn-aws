terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local backend keeps this runnable with zero extra bootstrapping (no S3 bucket /
  # DynamoDB lock table to create first). Tenant configs read this state via a
  # terraform_remote_state data source pointed at ./terraform.tfstate.
  # For real production use, swap this for an "s3" backend with state locking —
  # the tenant configs' remote_state blocks only need their `backend`/`config`
  # updated to match, nothing else changes.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}
