variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_cluster_security_group_id" { type = string }

variable "multi_az" {
  description = "Multi-AZ costs roughly 2x a single instance. Keep true only while actively testing failover (Phase 9); toggle false for routine day-to-day dev work."
  type        = bool
  default     = false
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro" # Graviton, cheapest Multi-AZ-capable class
}

resource "random_password" "db_master" {
  length  = 24
  special = false # avoids characters that need extra escaping in connection strings
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}/rds/master-credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "finledger_admin"
    password = random_password.db_master.result
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  vpc_id      = var.vpc_id

  # Only the EKS cluster's own security group can reach Postgres — nothing
  # else in the VPC, and nothing from the internet.
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-postgres"
  engine         = "postgres"
  engine_version = "17.6"
  instance_class = var.instance_class

  allocated_storage     = 20
  storage_type           = "gp3"
  storage_encrypted      = true # KMS default key; use a customer-managed key if this needs to show up as its own Phase 8 story

  db_name  = "finledger"
  username = "finledger_admin"
  password = random_password.db_master.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = var.multi_az
  publicly_accessible = false
  skip_final_snapshot = true # fine for a portfolio project; a real prod DB should never set this to true

  # This is the tag Phase 0's stop/start Lambda looks for. If you forget this
  # tag, the RDS instance runs 24/7 and the nightly cost guardrail silently
  # does nothing about it.
  tags = {
    auto_shutdown = "true"
    project       = var.project_name
  }
}

output "endpoint" { value = aws_db_instance.main.address }
output "port" { value = aws_db_instance.main.port }
output "db_instance_identifier" { value = aws_db_instance.main.identifier }
output "secret_arn" { value = aws_secretsmanager_secret.db_credentials.arn }