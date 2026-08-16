locals {
  # AWS Budgets tag filter format is "user:TagKey$TagValue".
  # format() is used instead of "${...}" string interpolation because a literal
  # "$" immediately followed by "{" has special escaping meaning in Terraform
  # and would otherwise break this string.
  budget_tag_filter = format("user:project$%s", var.project_name)
}

resource "aws_budgets_budget" "monthly_cap" {
  name         = "${var.project_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Only counts spend from resources tagged project=finledger, so this budget
  # doesn't get muddied if you have other things running in the same account.
  cost_filter {
    name   = "TagKeyValue"
    values = [local.budget_tag_filter]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # Forecasted alert catches you EARLY — before you actually hit the cap,
  # based on your current spend trajectory for the month.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}
