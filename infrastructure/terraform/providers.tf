terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state is fine while you're the only one working on this. If this
  # were a team project, this block would point to an S3 backend + DynamoDB
  # lock table instead — worth naming as a known next step, not doing
  # prematurely for a single-person portfolio repo.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project       = var.project_name
      managed_by    = "terraform"
      auto_shutdown = "true"
      environment   = "dev"
    }
  }
}