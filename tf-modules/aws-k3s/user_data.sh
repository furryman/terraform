#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k3s-init.log) 2>&1

echo "=== Starting k3s and ArgoCD installation ==="

# Wait for network connectivity
until ping -c1 google.com &>/dev/null; do
  echo "Waiting for network..."
  sleep 2
done

# Get instance public IP for TLS SAN
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

# Install k3s (single-node server)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --write-kubeconfig-mode=644 \
  --tls-san=$PUBLIC_IP \
  --disable=traefik" \
  sh -

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..."
until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done
echo "k3s is ready."

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install Helm
curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Create ArgoCD namespace
/usr/local/bin/kubectl create namespace argocd

# Add ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD via Helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "${argocd_chart_version}" \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttps=30443 \
  --set 'server.extraArgs[0]=--insecure' \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 300s

# Wait for ArgoCD server to be ready
echo "Waiting for ArgoCD server..."
/usr/local/bin/kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

# Install argocd-apps chart (App-of-Apps pattern)
cat <<'APPEOF' > /tmp/argocd-apps-values.yaml
applications:
  - name: app-of-apps
    namespace: argocd
    project: default
    source:
      repoURL: "${app_of_apps_repo_url}"
      path: "."
      targetRevision: HEAD
    destination:
      server: "https://kubernetes.default.svc"
      namespace: argocd
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
APPEOF

helm install argocd-apps argo/argocd-apps \
  --namespace argocd \
  --version "1.6.2" \
  -f /tmp/argocd-apps-values.yaml \
  --wait --timeout 120s

rm -f /tmp/argocd-apps-values.yaml

echo "=== k3s and ArgoCD installation complete ==="
echo "ArgoCD admin password:"
/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
