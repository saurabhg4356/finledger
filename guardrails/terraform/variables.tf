variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1" # Mumbai
}

variable "project_name" {
  description = "Project tag used across all resources and for cost filtering"
  type        = string
  default     = "finledger"
}

variable "alert_email" {
  description = "Email address to receive budget alert notifications"
  type        = string
  # No default on purpose — pass this via terraform.tfvars or -var so you don't
  # accidentally commit your email to a public repo.
}

variable "monthly_budget_limit_usd" {
  description = "Hard monthly spend cap in USD for this project"
  type        = string
  default     = "20" # adjust to whatever ceiling you're comfortable with
}

variable "rds_instance_identifier" {
  description = "Identifier of the RDS instance to auto stop/start. Leave empty until Phase 4 creates it."
  type        = string
  default     = ""
}

variable "stop_schedule_cron" {
  description = "UTC cron expression for nightly RDS stop (default: 9:00 PM IST = 15:30 UTC, Mon-Sat)"
  type        = string
  default     = "cron(30 15 ? * MON-SAT *)"
}

variable "start_schedule_cron" {
  description = "UTC cron expression for morning RDS start (default: 9:00 AM IST = 03:30 UTC, Mon-Sat)"
  type        = string
  default     = "cron(30 3 ? * MON-SAT *)"
}
