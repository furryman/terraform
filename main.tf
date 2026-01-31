# Main Terraform Configuration
# Orchestrates VPC, EKS, and ArgoCD modules

locals {
  tags = {
    Environment = var.environment
    Cluster     = var.cluster_name
    ManagedBy   = "Terraform"
  }
}

# VPC Module
module "vpc" {
  source = "./tf-modules/aws-vpc"

  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  tags         = local.tags
}

# EKS Module
module "eks" {
  source = "./tf-modules/aws-eks"

  cluster_name        = var.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  tags                = local.tags

  depends_on = [module.vpc]
}

# ArgoCD Module
module "argocd" {
  source = "./tf-modules/helm-argocd"

  app_of_apps_repo_url = var.app_of_apps_repo_url

  depends_on = [module.eks]
}
