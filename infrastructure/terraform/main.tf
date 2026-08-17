module "networking" {
  source       = "./modules/networking"
  project_name = var.project_name
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

module "eks" {
  source              = "./modules/eks"
  project_name        = var.project_name
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  public_subnet_ids   = module.networking.public_subnet_ids
}

module "rds" {
  source                         = "./modules/rds"
  project_name                   = var.project_name
  vpc_id                         = module.networking.vpc_id
  private_subnet_ids             = module.networking.private_subnet_ids
  eks_cluster_security_group_id  = module.eks.cluster_security_group_id
  multi_az                       = var.rds_multi_az
}

module "elasticache" {
  source                         = "./modules/elasticache"
  project_name                   = var.project_name
  vpc_id                         = module.networking.vpc_id
  private_subnet_ids             = module.networking.private_subnet_ids
  eks_cluster_security_group_id  = module.eks.cluster_security_group_id
}