# ------------------------------------------------------------------------------
# The Phase 4 secret (finledger/rds/credential) only ever held
# username/password — DB_HOST, DB_NAME, and REDIS_HOST were never in Secrets
# Manager at all, only visible via `terraform output`. ESO needs everything
# it syncs to actually live in Secrets Manager, so this adds a second,
# smaller secret for the connection info and leaves credentials where they
# already are. This models a genuinely common real pattern: composing one
# application Secret from multiple upstream sources, not everything living
# in a single blob.
# ------------------------------------------------------------------------------
data "aws_db_instance" "existing" {
  db_instance_identifier = "${var.project_name}-postgres"
}

data "aws_elasticache_cluster" "existing" {
  cluster_id = "${var.project_name}-redis"
}

resource "aws_secretsmanager_secret" "app_config" {
  name = "${var.project_name}/app/connection-config"
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode({
    DB_HOST    = data.aws_db_instance.existing.address
    DB_NAME    = "finledger"
    REDIS_HOST = data.aws_elasticache_cluster.existing.cache_nodes[0].address
  })
}

data "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}/rds/master-credential"
}

# ------------------------------------------------------------------------------
# IRSA role for ESO — scoped to GetSecretValue/DescribeSecret on exactly
# these two secret ARNs, nothing account-wide. This is what replaces the
# Phase 5 manual `kubectl create secret` — after this, the real DB password
# never touches a shell history or a human's clipboard again; ESO pulls it
# directly from Secrets Manager into the cluster.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "eso_trust" {
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
      values   = ["system:serviceaccount:finledger:external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.project_name}-external-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.eso_trust.json
}

resource "aws_iam_role_policy" "eso_secrets_read" {
  name = "${var.project_name}-eso-secrets-read"
  role = aws_iam_role.eso.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [
        data.aws_secretsmanager_secret.db_credentials.arn,
        aws_secretsmanager_secret.app_config.arn,
      ]
    }]
  })
}

output "eso_role_arn" { value = aws_iam_role.eso.arn }