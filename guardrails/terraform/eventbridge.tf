resource "aws_cloudwatch_event_rule" "nightly_stop" {
  name                = "${var.project_name}-nightly-rds-stop"
  description         = "Stops tagged RDS instances outside working hours"
  schedule_expression = var.stop_schedule_cron
}

resource "aws_cloudwatch_event_target" "nightly_stop_target" {
  rule = aws_cloudwatch_event_rule.nightly_stop.name
  arn  = aws_lambda_function.stop_rds.arn
}

resource "aws_lambda_permission" "allow_eventbridge_stop" {
  statement_id  = "AllowEventBridgeInvokeStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_rds.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nightly_stop.arn
}

resource "aws_cloudwatch_event_rule" "morning_start" {
  name                = "${var.project_name}-morning-rds-start"
  description         = "Starts tagged RDS instances at the beginning of working hours"
  schedule_expression = var.start_schedule_cron
}

resource "aws_cloudwatch_event_target" "morning_start_target" {
  rule = aws_cloudwatch_event_rule.morning_start.name
  arn  = aws_lambda_function.start_rds.arn
}

resource "aws_lambda_permission" "allow_eventbridge_start" {
  statement_id  = "AllowEventBridgeInvokeStart"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_rds.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.morning_start.arn
}
