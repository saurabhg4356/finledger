terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "finledger"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project       = var.project_name
      managed_by    = "terraform"
      auto_shutdown = "true"
      environment   = "dev"
    }
  }
}

module "messaging" {
  source       = "./modules/messaging"
  project_name = var.project_name
}

output "sns_topic_arn" { value = module.messaging.topic_arn }
output "fraud_queue_url" { value = module.messaging.fraud_queue_url }
output "fraud_dlq_url" { value = module.messaging.fraud_dlq_url }
output "notification_queue_url" { value = module.messaging.notification_queue_url }
output "notification_dlq_url" { value = module.messaging.notification_dlq_url }