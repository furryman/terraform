variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
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
}

variable "instance_type" {
  description = "EC2 instance type for the k3s node"
  type        = string
  default     = "t3.small"  # 2GB RAM - enough for k3s + ArgoCD
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 instance access"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed for SSH and k3s API access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
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
}
