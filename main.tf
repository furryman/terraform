# Main Terraform Configuration
# Orchestrates VPC and k3s modules

locals {
  # Environment, ManagedBy, Project come from provider default_tags (providers.tf).
  # Only module-specific tags live here.
  tags = {
    Cluster = var.cluster_name
  }
}

# VPC Module
module "vpc" {
  source = "./tf-modules/aws-vpc"

  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  tags         = local.tags
}

# k3s Module (replaces EKS + ArgoCD)
module "k3s" {
  source = "./tf-modules/aws-k3s"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  subnet_id            = module.vpc.public_subnet_id
  instance_type        = var.instance_type
  volume_size          = var.volume_size
  allowed_admin_cidrs  = var.allowed_admin_cidrs
  app_of_apps_repo_url = var.app_of_apps_repo_url
  argocd_chart_version = var.argocd_chart_version
  tags                 = local.tags
}
