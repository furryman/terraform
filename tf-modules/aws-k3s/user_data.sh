#!/bin/bash
set -euo pipefail

# Ensure log directory exists and redirect all output
mkdir -p /var/log
exec > >(tee -a /var/log/k3s-init.log) 2>&1

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

# Wait for ingress-nginx to be deployed by ArgoCD
echo "Waiting for ingress-nginx to be deployed..."
until /usr/local/bin/kubectl get namespace ingress-nginx &>/dev/null; do
  echo "Waiting for ingress-nginx namespace..."
  sleep 5
done

echo "Waiting for ingress-nginx service..."
until /usr/local/bin/kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; do
  sleep 5
done

# Wait for service to have ClusterIP assigned
until INGRESS_IP=$(/usr/local/bin/kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null) && [ -n "$INGRESS_IP" ]; do
  echo "Waiting for ingress-nginx ClusterIP..."
  sleep 5
done

echo "Ingress-nginx ClusterIP: $INGRESS_IP"

# Configure CoreDNS for split-horizon DNS (hairpin NAT workaround)
echo "Configuring CoreDNS for internal DNS resolution..."
/usr/local/bin/kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-backup.yaml

# Patch CoreDNS to add custom DNS entries
/usr/local/bin/kubectl get configmap coredns -n kube-system -o yaml | \
  awk -v ip="$INGRESS_IP" '/NodeHosts: \|/{print; print "    " ip " fuhriman.org"; print "    " ip " www.fuhriman.org"; next}1' | \
  /usr/local/bin/kubectl apply -f -

# Restart CoreDNS to pick up changes
echo "Restarting CoreDNS..."
/usr/local/bin/kubectl rollout restart deployment coredns -n kube-system
/usr/local/bin/kubectl rollout status deployment coredns -n kube-system --timeout=60s

echo "CoreDNS configured for internal resolution of fuhriman.org and www.fuhriman.org to $INGRESS_IP"

echo "=== k3s and ArgoCD installation complete ==="
echo "ArgoCD admin password:"
/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
