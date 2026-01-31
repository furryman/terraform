output "argocd_namespace" {
  description = "The namespace where ArgoCD is installed"
  value       = kubernetes_namespace.argocd.metadata[0].name
}

output "argocd_release_name" {
  description = "The name of the ArgoCD Helm release"
  value       = helm_release.argocd.name
}
