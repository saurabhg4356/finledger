variable "eks_cluster_name" {
  type    = string
  default = "finledger-cluster"
}

variable "k8s_namespace" {
  type    = string
  default = "finledger"
}

data "aws_eks_cluster" "main" {
  name = var.eks_cluster_name
}

# ------------------------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts) — this is how the poller, fraud-service,
# and notification-service call SNS/SQS without any AWS access keys baked into
# a container image or Kubernetes Secret. Each pod authenticates as a specific
# Kubernetes ServiceAccount; AWS trusts the CLUSTER's own OIDC issuer (separate
# from the GitHub Actions OIDC provider set up in Phase 5 — two different OIDC
# trust relationships doing two different jobs) to vouch for that identity.
# ------------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_issuer_no_scheme = replace(data.aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# ---- Helper: one IAM role per ServiceAccount, trust scoped to that exact SA --
# (Terraform doesn't have a clean "module of one resource" shortcut without
# introducing a real module, so these three roles are written out explicitly
# rather than looped — makes the least-privilege boundary between them
# obvious at a glance, which matters more here than DRY-ing up ~15 lines.)

# ---- outbox-poller: only needs to publish to SNS -----------------------------
data "aws_iam_policy_document" "poller_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:outbox-poller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "poller" {
  name               = "finledger-outbox-poller-role"
  assume_role_policy = data.aws_iam_policy_document.poller_trust.json
}

resource "aws_iam_role_policy" "poller_sns_publish" {
  name = "finledger-poller-sns-publish"
  role = aws_iam_role.poller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = module.messaging.topic_arn
    }]
  })
}

# ---- fraud-service: only needs its own queue ----------------------------------
data "aws_iam_policy_document" "fraud_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:fraud-service"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fraud_service" {
  name               = "finledger-fraud-service-role"
  assume_role_policy = data.aws_iam_policy_document.fraud_trust.json
}

resource "aws_iam_role_policy" "fraud_sqs_consume" {
  name = "finledger-fraud-sqs-consume"
  role = aws_iam_role.fraud_service.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = module.messaging.fraud_queue_arn
    }]
  })
}

# ---- notification-service: only needs its own queue ---------------------------
data "aws_iam_policy_document" "notification_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:notification-service"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "notification_service" {
  name               = "finledger-notification-service-role"
  assume_role_policy = data.aws_iam_policy_document.notification_trust.json
}

resource "aws_iam_role_policy" "notification_sqs_consume" {
  name = "finledger-notification-sqs-consume"
  role = aws_iam_role.notification_service.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = module.messaging.notification_queue_arn
    }]
  })
}

output "poller_role_arn" { value = aws_iam_role.poller.arn }
output "fraud_service_role_arn" { value = aws_iam_role.fraud_service.arn }
output "notification_service_role_arn" { value = aws_iam_role.notification_service.arn }