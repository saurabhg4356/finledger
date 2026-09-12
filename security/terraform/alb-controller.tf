# ------------------------------------------------------------------------------
# Policy fetched directly from the official source and used verbatim
# (kubernetes-sigs/aws-load-balancer-controller, docs/install/iam_policy.json,
# main branch) rather than reconstructed from memory. This policy is long
# and easy to get subtly wrong — a single missing action causes a silent,
# hard-to-diagnose controller failure (an Ingress that never gets an ALB, no
# useful error), so it's worth pulling the current version yourself before
# applying this if time has passed: docs/install/iam_policy.json in that repo.
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "alb_controller_trust" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_trust.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.project_name}-alb-controller-policy"
  policy = file("${path.module}/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }