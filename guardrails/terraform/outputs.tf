output "budget_alerts_sns_topic_arn" {
  value = aws_sns_topic.budget_alerts.arn
}

output "stop_rds_lambda_name" {
  value = aws_lambda_function.stop_rds.function_name
}

output "start_rds_lambda_name" {
  value = aws_lambda_function.start_rds.function_name
}

output "next_step" {
  value = "Confirm the SNS email subscription in your inbox, then run 'terraform apply' before creating any other AWS resources."
}
