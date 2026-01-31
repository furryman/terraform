variable "argocd_version" {
  description = "Version of the ArgoCD Helm chart"
  type        = string
  default     = "5.55.0"
}

variable "argocd_apps_version" {
  description = "Version of the argocd-apps Helm chart"
  type        = string
  default     = "1.6.2"
}

variable "app_of_apps_repo_url" {
  description = "Git repository URL for the app-of-apps chart"
  type        = string
}
