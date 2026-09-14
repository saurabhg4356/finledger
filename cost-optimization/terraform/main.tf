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

data "aws_iam_role" "fargate_pod_execution" {
  name = "${var.project_name}-eks-fargate-pod-execution-role"
}

locals {
  oidc_issuer_no_scheme = replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
  eks_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_no_scheme}"
}

# ------------------------------------------------------------------------------
# A new namespace + matching Fargate profile, same pattern as every prior
# phase that added a namespace (monitoring in Phase 7, finledger in Phase 4).
# The ADOT collector needs its own dedicated namespace because its
# ClusterRole grants read access to nodes/pods/services cluster-wide — worth
# keeping that separate from application workloads for a clean blast radius.
# ------------------------------------------------------------------------------

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.main.vpc_config[0].vpc_id]
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eks_fargate_profile" "container_insights" {
  cluster_name           = var.eks_cluster_name
  fargate_profile_name   = "fargate-container-insights"
  pod_execution_role_arn = data.aws_iam_role.fargate_pod_execution.arn
  subnet_ids              = data.aws_subnets.private.ids

  selector {
    namespace = "fargate-container-insights"
  }
}

# ------------------------------------------------------------------------------
# IRSA for the ADOT collector's ServiceAccount. Uses the AWS-managed
# CloudWatchAgentServerPolicy — this is what AWS's own ADOT Fargate setup
# guide specifies, not a custom policy, since the collector needs the same
# breadth of CloudWatch Logs/Metrics write access the CloudWatch agent itself
# would need in any deployment mode.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "adot_collector_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.eks_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:sub"
      values   = ["system:serviceaccount:fargate-container-insights:adot-collector"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "adot_collector" {
  name               = "${var.project_name}-adot-collector-role"
  assume_role_policy = data.aws_iam_policy_document.adot_collector_trust.json
}

resource "aws_iam_role_policy_attachment" "adot_collector_cloudwatch" {
  role       = aws_iam_role.adot_collector.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

output "adot_collector_role_arn" { value = aws_iam_role.adot_collector.arn }