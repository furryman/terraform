variable "cluster_name" {
  description = "Name prefix for k3s resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the instance will be created"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. No default — root module forwards its own value."
  type        = string
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}

variable "allowed_admin_cidrs" {
  description = "CIDR blocks allowed for SSH (22), k3s API (6443), and ArgoCD UI (30443)"
  type        = list(string)
}

variable "app_of_apps_repo_url" {
  description = "Git repository URL for the ArgoCD app-of-apps chart"
  type        = string
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "5.55.0"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
