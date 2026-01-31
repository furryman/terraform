# Helm ArgoCD Module
# Deploys ArgoCD and argocd-apps Helm charts

# ArgoCD Namespace
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# ArgoCD Helm Release
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    yamlencode({
      server = {
        service = {
          type = "LoadBalancer"
        }
        extraArgs = [
          "--insecure"
        ]
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]

  wait = true

  depends_on = [kubernetes_namespace.argocd]
}

# ArgoCD Apps Helm Release (App of Apps)
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    yamlencode({
      applications = [
        {
          name      = "app-of-apps"
          namespace = "argocd"
          project   = "default"
          source = {
            repoURL        = var.app_of_apps_repo_url
            path           = "."
            targetRevision = "HEAD"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
            syncOptions = [
              "CreateNamespace=true"
            ]
          }
        }
      ]
    })
  ]

  depends_on = [helm_release.argocd]
}
