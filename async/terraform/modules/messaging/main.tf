variable "project_name" { type = string }

# ------------------------------------------------------------------------------
# WHY SNS + two SQS queues, not one shared SQS queue
#
# A single SQS queue is a COMPETING-CONSUMERS pattern: each message is
# delivered to exactly ONE consumer, then deleted. If fraud-service and
# notification-service both polled the same queue, each transaction would
# only be seen by whichever service happened to grab it first — the other
# would silently never see it.
#
# What this actually needs is FAN-OUT: every completed transaction must reach
# BOTH fraud-service AND notification-service, independently. SNS does that —
# it publishes one message to N subscribed SQS queues, each getting its own
# copy with its own independent redrive/DLQ behavior. This is the standard
# AWS fan-out pattern and a common system-design interview topic in its own
# right ("how would you notify multiple independent services of one event?").
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "transaction_events" {
  name = "${var.project_name}-transaction-events"
}

# ---- Fraud queue + DLQ -------------------------------------------------------
resource "aws_sqs_queue" "fraud_dlq" {
  name                      = "${var.project_name}-fraud-dlq"
  message_retention_seconds = 1209600 # 14 days — max retention, gives time to notice and investigate
}

resource "aws_sqs_queue" "fraud_queue" {
  name                       = "${var.project_name}-fraud-queue"
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.fraud_dlq.arn
    maxReceiveCount      = 3 # after 3 failed processing attempts, SQS moves the message to the DLQ automatically — no app-level DLQ logic needed
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "fraud_dlq_allow" {
  queue_url = aws_sqs_queue.fraud_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.fraud_queue.arn]
  })
}

resource "aws_sqs_queue_policy" "fraud_queue_policy" {
  queue_url = aws_sqs_queue.fraud_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.fraud_queue.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.transaction_events.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "fraud_sub" {
  topic_arn = aws_sns_topic.transaction_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.fraud_queue.arn
}

# ---- Notification queue + DLQ ------------------------------------------------
resource "aws_sqs_queue" "notification_dlq" {
  name                      = "${var.project_name}-notification-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "notification_queue" {
  name                       = "${var.project_name}-notification-queue"
  visibility_timeout_seconds = 30
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn
    maxReceiveCount      = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "notification_dlq_allow" {
  queue_url = aws_sqs_queue.notification_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.notification_queue.arn]
  })
}

resource "aws_sqs_queue_policy" "notification_queue_policy" {
  queue_url = aws_sqs_queue.notification_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.notification_queue.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.transaction_events.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "notification_sub" {
  topic_arn = aws_sns_topic.transaction_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notification_queue.arn
}

output "topic_arn" { value = aws_sns_topic.transaction_events.arn }
output "fraud_queue_url" { value = aws_sqs_queue.fraud_queue.id }
output "fraud_queue_arn" { value = aws_sqs_queue.fraud_queue.arn }
output "fraud_dlq_url" { value = aws_sqs_queue.fraud_dlq.id }
output "fraud_dlq_arn" { value = aws_sqs_queue.fraud_dlq.arn }
output "notification_queue_url" { value = aws_sqs_queue.notification_queue.id }
output "notification_queue_arn" { value = aws_sqs_queue.notification_queue.arn }
output "notification_dlq_url" { value = aws_sqs_queue.notification_dlq.id }
output "notification_dlq_arn" { value = aws_sqs_queue.notification_dlq.arn }