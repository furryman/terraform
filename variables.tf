variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "Must be a valid AWS region (e.g., us-west-2)."
  }
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "fuhriman-k3s"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Must be a valid IPv4 CIDR block (e.g., 10.0.0.0/16)."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the k3s node"
  type        = string
  default     = "t3.small" # 2GB RAM — enough for k3s + ArgoCD

  validation {
    condition     = can(regex("^(t3|t3a|t4g)\\.(small|medium|large)$", var.instance_type))
    error_message = "Must be a t3.*, t3a.*, or t4g.* (small/medium/large) — burst-tier instances only."
  }
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20

  validation {
    condition     = var.volume_size >= 20 && var.volume_size <= 100
    error_message = "Volume size must be between 20 and 100 GB for a portfolio k3s node."
  }
}

variable "allowed_admin_cidrs" {
  description = "CIDR blocks allowed for SSH (22), k3s API (6443), and ArgoCD UI (30443). No default — must be set in terraform.tfvars to avoid 0.0.0.0/0 exposure."
  type        = list(string)
}

variable "app_of_apps_repo_url" {
  description = "Git repository URL for the app-of-apps chart"
  type        = string
  default     = "https://github.com/furryman/argocd-app-of-apps.git"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.55.0"
}

variable "budget_notification_email" {
  description = "Email address for AWS budget alert notifications"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.budget_notification_email))
    error_message = "Must be a valid email address."
  }
}
