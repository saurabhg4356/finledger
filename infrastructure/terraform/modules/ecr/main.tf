variable "project_name" { type = string }

variable "service_names" {
  type    = list(string)
  default = ["account-service", "ledger-service", "transaction-service"]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(var.service_names)
  name                 = "${var.project_name}-${each.value}"
  image_tag_mutability = "IMMUTABLE" # prevents accidentally overwriting a tag like "latest" that's already deployed

  image_scanning_configuration {
    scan_on_push = true # this is what feeds Trivy-equivalent vulnerability data — catches an outdated base image before it reaches EKS
  }
}

# Keep only the last 10 images per repo so ECR storage cost doesn't grow unbounded
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}