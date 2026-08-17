output "vpc_id" { value = module.networking.vpc_id }

output "eks_cluster_name" { value = module.eks.cluster_name }
output "eks_cluster_endpoint" { value = module.eks.cluster_endpoint }

output "ecr_repository_urls" { value = module.ecr.repository_urls }

output "rds_endpoint" { value = module.rds.endpoint }
output "rds_secret_arn" {
  value       = module.rds.secret_arn
  description = "Fetch actual credentials with: aws secretsmanager get-secret-value --secret-id <this-arn>"
}

output "redis_endpoint" { value = module.elasticache.endpoint }

output "next_step" {
  value = "Run: aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}. Then patch CoreDNS to run on Fargate — see README Step 4."
}