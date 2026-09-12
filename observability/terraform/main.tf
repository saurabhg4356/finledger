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

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.main.vpc_config[0].vpc_id]
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
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

data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

# Reuses the SAME Fargate pod execution role created back in Phase 4 —
# no reason to create a second one just because this is a new namespace.
data "aws_iam_role" "fargate_pod_execution" {
  name = "${var.project_name}-eks-fargate-pod-execution-role"
}

# ------------------------------------------------------------------------------
# A dedicated Fargate profile for the "monitoring" namespace, same pattern as
# the "finledger" profile from Phase 4 — every namespace that needs pods
# scheduled on Fargate needs its own matching profile; there's no default
# catch-all.
# ------------------------------------------------------------------------------
resource "aws_eks_fargate_profile" "monitoring" {
  cluster_name           = var.eks_cluster_name
  fargate_profile_name   = "monitoring"
  pod_execution_role_arn = data.aws_iam_role.fargate_pod_execution.arn
  subnet_ids              = data.aws_subnets.private.ids

  selector {
    namespace = "monitoring"
  }
}

# ------------------------------------------------------------------------------
# IRSA for the CloudWatch exporter (YACE — yet-another-cloudwatch-exporter),
# which is what bridges SQS queue-depth metrics (a CloudWatch-native metric,
# not something any FinLedger service produces itself) into Prometheus.
# Read-only: ListMetrics/GetMetricData/GetMetricStatistics, nothing else.
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  oidc_issuer_no_scheme = replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
  # Reused here via a constructed ARN rather than a re-declared resource —
  # the OIDC provider itself was already created in Phase 6's irsa.tf;
  # creating it again would fail with EntityAlreadyExists.
  eks_oidc_provider_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_issuer_no_scheme}"
}

data "aws_iam_policy_document" "cloudwatch_exporter_trust" {
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
      values   = ["system:serviceaccount:monitoring:cloudwatch-exporter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_exporter" {
  name               = "${var.project_name}-cloudwatch-exporter-role"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_exporter_trust.json
}

resource "aws_iam_role_policy" "cloudwatch_exporter_readonly" {
  name = "${var.project_name}-cloudwatch-exporter-readonly"
  role = aws_iam_role.cloudwatch_exporter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "tag:GetResources",
      ]
      Resource = "*" # CloudWatch's read APIs don't support resource-level scoping — this is genuinely as narrow as it gets, and it's read-only
    }]
  })
}



output "cloudwatch_exporter_role_arn" { value = aws_iam_role.cloudwatch_exporter.arn }