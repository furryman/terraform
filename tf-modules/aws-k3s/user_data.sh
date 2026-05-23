#!/bin/bash
# Runtime bootstrap. Most install-time work (k3s binary, helm, kubectl,
# repo cache, ssm-agent) is pre-baked into the Packer AMI. This script
# wires the instance-specific bits at first boot.
set -euo pipefail

mkdir -p /var/log
exec > >(tee -a /var/log/k3s-init.log) 2>&1

echo "=== Runtime bootstrap on Packer AMI ==="

# Wait for network egress.
until curl -sf -o /dev/null https://get.k3s.io --max-time 5; do
  echo "waiting for network..."
  sleep 2
done

# SSM Agent is preinstalled by the Packer AMI but defaults to disabled —
# explicitly enable so admin access via `aws ssm start-session` works.
systemctl enable --now amazon-ssm-agent

# Pull the instance's public IP from IMDSv2 for k3s TLS-SAN.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

# Re-run the k3s installer with the runtime --tls-san. SKIP_DOWNLOAD=true
# means we reuse the binary baked into the AMI; the script just rewrites
# /etc/systemd/system/k3s.service with the right args and starts the
# service. Takes ~5 sec.
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode=644 --tls-san=$PUBLIC_IP" \
  sh -

# Wait for k3s API to be ready.
until /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 3
done
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install ArgoCD. helm + the argo repo cache are pre-baked.
/usr/local/bin/kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "${argocd_chart_version}" \
  --set 'configs.params.server\.insecure=true' \
  --wait --timeout 300s

# Install App-of-Apps so ArgoCD takes over cluster-state management.
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

echo "=== Runtime bootstrap complete ==="
