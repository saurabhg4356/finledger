variable "project_name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_cluster_security_group_id" { type = string }

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.project_name}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-redis-sg" }
}

# Single node, no replication — this is a latency-optimization cache for
# idempotency-key pre-checks, NOT the source of truth (the Postgres UNIQUE
# constraint is). If this node is lost, worst case is a slightly slower retry
# path while it's rebuilt, not a correctness problem. That's the justification
# for skipping a replication group here despite ElastiCache having no
# stop/start like RDS does (see Phase 0 README's "known trade-offs" section).
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "${var.project_name}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  num_cache_nodes      = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
}

output "endpoint" { value = aws_elasticache_cluster.redis.cache_nodes[0].address }
output "port" { value = aws_elasticache_cluster.redis.cache_nodes[0].port }