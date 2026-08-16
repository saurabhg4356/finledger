# OPTIONAL — the "hard stop" layer.
#
# The SNS notifications in budget.tf only alert you; they don't stop anything.
# This resource goes one step further: at 100% of the budget, AWS automatically
# attaches a deny-new-resources IAM policy to a role you specify, so runaway
# spend can't continue even if you don't see the email in time.
#
# This is intentionally an IAM-policy attach/detach action rather than a
# "delete everything" Lambda — it's reversible (detach the policy once you've
# reviewed what happened) and can't accidentally destroy something unrelated.
# This trade-off — reversible containment over destructive auto-cleanup — is
# worth being able to explain in an interview.
#
# Requires an IAM role that Budget Actions is allowed to assume. Uncomment and
# set var.deployment_role_name to the role your Terraform/CI pipeline uses.

# resource "aws_iam_policy" "deny_new_resources" {
#   name = "${var.project_name}-budget-deny-policy"
#
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Sid      = "DenyNewResourceCreation"
#       Effect   = "Deny"
#       Action   = ["ec2:RunInstances", "rds:CreateDBInstance", "eks:CreateCluster"]
#       Resource = "*"
#     }]
#   })
# }
#
# resource "aws_iam_role" "budget_action_role" {
#   name = "${var.project_name}-budget-action-role"
#
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [{
#       Effect    = "Allow"
#       Principal = { Service = "budgets.amazonaws.com" }
#       Action    = "sts:AssumeRole"
#     }]
#   })
# }
#
# resource "aws_budgets_budget_action" "deny_at_100_percent" {
#   budget_name        = aws_budgets_budget.monthly_cap.name
#   action_type        = "APPLY_IAM_POLICY"
#   approval_model     = "AUTOMATIC"
#   notification_type  = "ACTUAL"
#   execution_role_arn = aws_iam_role.budget_action_role.arn
#
#   action_threshold {
#     action_threshold_type  = "PERCENTAGE"
#     action_threshold_value = 100
#   }
#
#   definition {
#     iam_action_definition {
#       policy_arn = aws_iam_policy.deny_new_resources.arn
#       roles      = [var.deployment_role_name]
#     }
#   }
#
#   subscriber {
#     subscription_type = "EMAIL"
#     address            = var.alert_email
#   }
# }
