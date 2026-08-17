variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "finledger"
}

variable "github_owner" {
  type    = string
  default = "saurabhg4356"
}

variable "github_repo" {
  type    = string
  default = "finledger"
}

variable "eks_cluster_name" {
  type    = string
  default = "finledger-cluster"
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# OIDC provider trusting GitHub's token issuer.
#
# thumbprint_list is technically ignored by AWS at runtime for GitHub's
# provider on current SDK versions (AWS added GitHub to a trusted root CA
# list), but is still included here for compatibility with AWS provider
# versions < 6.x where the field is required at creation time. Safe either way.
# ------------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ------------------------------------------------------------------------------
# Trust policy — this is the part most guides get subtly wrong right now.
#
# GitHub rolled out an "immutable subject claim" format for NEW repositories
# starting July 15, 2026, which embeds numeric owner/repo IDs:
#     repo:saurabhg4356@<owner-id>/finledger@<repo-id>:ref:refs/heads/main
# instead of the classic:
#     repo:saurabhg4356/finledger:ref:refs/heads/main
#
# Since this repo may have been created after that date, a trust policy
# pinned to the classic format could silently fail with an opaque
# "not authorized to perform sts:AssumeRoleWithWebIdentity" error. The
# StringLike wildcard pattern below matches BOTH formats, since the owner
# and repo *names* still appear in both — only the optional "@<id>" suffix
# differs.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}*/${var.github_repo}*:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name               = "${var.project_name}-github-actions-ci"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# ------------------------------------------------------------------------------
# Least-privilege permissions: push to THIS project's ECR repos only, describe
# the cluster to fetch a kubeconfig. Nothing account-wide.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "ci_permissions" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this specific action does not support resource-level scoping
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-account-service",
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-ledger-service",
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-transaction-service",
    ]
  }

  statement {
    sid       = "DescribeClusterForKubeconfig"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.eks_cluster_name}"]
  }
}

resource "aws_iam_role_policy" "ci_permissions" {
  name   = "${var.project_name}-github-actions-ci-policy"
  role   = aws_iam_role.github_actions_ci.id
  policy = data.aws_iam_policy_document.ci_permissions.json
}

# ------------------------------------------------------------------------------
# EKS Access Entry — the current, non-deprecated way to grant an IAM principal
# kubectl permissions (replaces manually editing the aws-auth ConfigMap).
# Scoped to ONLY the finledger namespace, with edit (not admin) rights — the CI
# role can deploy/update workloads but can't touch RBAC, other namespaces, or
# cluster-scoped resources.
#
# REQUIRES: the EKS cluster's access_config.authentication_mode must include
# "API" (e.g. "API_AND_CONFIG_MAP"). If your Phase 4 cluster was created
# without this, add the access_config block to modules/eks/main.tf and
# `terraform apply` that change FIRST, or this resource will fail.
# ------------------------------------------------------------------------------
resource "aws_eks_access_entry" "github_actions_ci" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.github_actions_ci.arn
}

resource "aws_eks_access_policy_association" "github_actions_ci_edit" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.github_actions_ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["finledger"]
  }
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_ci.arn
  description = "Put this in the GitHub repo as a variable (Settings > Secrets and variables > Actions > Variables) named AWS_GITHUB_ACTIONS_ROLE_ARN"
}