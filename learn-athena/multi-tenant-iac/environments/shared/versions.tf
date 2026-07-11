terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Local backend keeps this runnable with no bootstrapping (no state bucket or
  # lock table to create first). Tenant environments read this state via a
  # terraform_remote_state data source.
  #
  # For production: switch to an "s3" backend with locking. The tenant configs'
  # remote_state blocks then need their backend/config updated to match —
  # nothing else changes.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}
