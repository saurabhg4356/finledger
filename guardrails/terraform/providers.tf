terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource created by this Terraform config inherits these tags automatically.
  # This is what makes the auto-shutdown Lambda able to find resources by tag
  # without you having to remember to tag each one manually.
  default_tags {
    tags = {
      project        = var.project_name
      managed_by     = "terraform"
      auto_shutdown  = "true"
      environment    = "dev"
    }
  }
}
