variable "project_name" { type = string }
variable "cluster_version" {
  type    = string
  default = "1.31"
}
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }

# ---- Cluster IAM role -------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---- Cluster ----------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true # convenient for local kubectl during a portfolio project; would restrict to false + VPN/bastion in a real prod setup
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions  = true
  }
}

# ---- Fargate pod execution role ---------------------------------------------
resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.project_name}-eks-fargate-pod-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution_policy" {
  role       = aws_iam_role.fargate_pod_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}

# ---- Fargate profile: kube-system --------------------------------------------
# CoreDNS ships by default expecting to run on EC2 nodes. On a Fargate-only
# cluster with no EC2 nodegroup, CoreDNS pods stay Pending forever unless a
# Fargate profile explicitly matches the kube-system namespace. This is the
# single most common first surprise on an EKS Fargate cluster.
resource "aws_eks_fargate_profile" "kube_system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "kube-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids              = var.private_subnet_ids

  selector {
    namespace = "kube-system"
  }
}

# ---- Fargate profile: application namespace ----------------------------------
resource "aws_eks_fargate_profile" "finledger" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "finledger"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids              = var.private_subnet_ids

  selector {
    namespace = "finledger"
  }
}

output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_certificate_authority_data" { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_security_group_id" { value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id }