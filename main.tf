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

# DNS Module — Route53 public hosted zone
module "dns" {
  source = "./tf-modules/aws-dns"

  domain_name = var.domain_name
  tags        = local.tags
}

# IAM policy granting ExternalDNS (running on the k3s instance) the Route53
# permissions it needs to manage records in our public zone.
# Lives in root rather than aws-dns module to avoid a circular dependency
# (the policy needs the zone ID; aws-k3s would otherwise need to know aws-dns).
resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns"
  description = "Allows ExternalDNS to manage Route53 records in the ${var.domain_name} zone"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ExternalDNSManageRecordSets"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${module.dns.zone_id}"
      },
      {
        Sid    = "ExternalDNSListAndGetChange"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
          "route53:GetChange"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.external_dns.arn
  role       = module.k3s.iam_role_name
}
