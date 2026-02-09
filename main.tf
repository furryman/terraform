# Main Terraform Configuration
# Orchestrates VPC and k3s modules

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

# k3s Module (replaces EKS + ArgoCD)
module "k3s" {
  source = "./tf-modules/aws-k3s"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  subnet_id            = module.vpc.public_subnet_id
  instance_type        = var.instance_type
  volume_size          = var.volume_size
  ssh_public_key       = var.ssh_public_key
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  app_of_apps_repo_url = var.app_of_apps_repo_url
  argocd_chart_version = var.argocd_chart_version
  tags                 = local.tags

  depends_on = [module.vpc]
}
