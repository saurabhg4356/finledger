data "archive_file" "stop_rds_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_code/stop_rds"
  output_path = "${path.module}/build/stop_rds.zip"
}

data "archive_file" "start_rds_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_code/start_rds"
  output_path = "${path.module}/build/start_rds.zip"
}

resource "aws_iam_role" "auto_shutdown_lambda_role" {
  name = "${var.project_name}-auto-shutdown-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Least-privilege policy: only the RDS actions this Lambda actually needs,
# plus the minimum CloudWatch Logs permissions. Worth pointing to in an
# interview as an example of scoping IAM roles down from AWS-managed defaults.
resource "aws_iam_role_policy" "auto_shutdown_lambda_policy" {
  name = "${var.project_name}-auto-shutdown-lambda-policy"
  role = aws_iam_role.auto_shutdown_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSStartStop"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:ListTagsForResource",
          "rds:StopDBInstance",
          "rds:StartDBInstance"
        ]
        Resource = "*"
      },
      {
        Sid    = "Logging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.project_name}-*"
      }
    ]
  })
}

resource "aws_lambda_function" "stop_rds" {
  function_name    = "${var.project_name}-stop-rds"
  role             = aws_iam_role.auto_shutdown_lambda_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"] # Graviton — cheaper and faster cold starts than x86
  timeout          = 30
  filename         = data.archive_file.stop_rds_zip.output_path
  source_code_hash = data.archive_file.stop_rds_zip.output_base64sha256
}

resource "aws_lambda_function" "start_rds" {
  function_name    = "${var.project_name}-start-rds"
  role             = aws_iam_role.auto_shutdown_lambda_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 30
  filename         = data.archive_file.start_rds_zip.output_path
  source_code_hash = data.archive_file.start_rds_zip.output_base64sha256
}
