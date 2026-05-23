terraform {
  # 1.15+ required for native S3 backend locking (use_lockfile).
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned to the 6.x line; patch + minor bumps allowed, major requires explicit decision.
      version = "~> 6.31"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = "fuhriman-website"
    }
  }
}
