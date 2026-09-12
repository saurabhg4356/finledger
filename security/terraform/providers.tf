terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "finledger"
}

variable "eks_cluster_name" {
  type    = string
  default = "finledger-cluster"
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

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

locals {
  oidc_issuer_no_scheme = replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
  # References the OIDC provider already created in Phase 6's irsa.tf — not
  # recreated here, just referenced via its constructed ARN (same pattern
  # Phase 7 used).
  eks_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_no_scheme}"
}