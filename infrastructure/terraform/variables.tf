variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "finledger"
}

variable "rds_multi_az" {
  description = "See modules/rds — leave false day-to-day, flip true only when running the Phase 9 failover chaos experiment."
  type        = bool
  default     = false
}