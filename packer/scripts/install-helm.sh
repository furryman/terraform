#!/bin/bash
# Install Helm and pre-populate the Helm repo cache so `helm install` at
# runtime doesn't have to fetch chart indexes for the first time.
#
# kubectl is intentionally NOT installed here — the k3s install in
# install-k3s.sh creates /usr/local/bin/kubectl as a symlink to /usr/local/bin/k3s,
# which auto-discovers the k3s kubeconfig at /etc/rancher/k3s/k3s.yaml.
# Installing upstream kubectl on top would overwrite the symlink and break
# auto-discovery.
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-v3.15.4}"

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)        ARCH_SUFFIX="amd64" ;;
    aarch64|arm64) ARCH_SUFFIX="arm64" ;;
    *) echo "ERROR: unsupported architecture: ${ARCH}"; exit 1 ;;
esac

echo "=== Installing helm ${HELM_VERSION} (${ARCH_SUFFIX}) ==="
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_SUFFIX}.tar.gz" \
    -o "${TMPDIR}/helm.tar.gz"
tar -xzf "${TMPDIR}/helm.tar.gz" -C "${TMPDIR}"
sudo install -m 0755 "${TMPDIR}/linux-${ARCH_SUFFIX}/helm" /usr/local/bin/helm
helm version --short

echo "=== Priming Helm repo cache (as root — user_data runs as root) ==="
# Repos are cached per-user in $HOME/.config/helm/repositories.yaml.
# user_data runs as root, so cache the repos under root's home; otherwise
# `helm install argo/argo-cd` at runtime fails with "repo argo not found".
sudo helm repo add argo https://argoproj.github.io/argo-helm
sudo helm repo add jetstack https://charts.jetstack.io
sudo helm repo update

echo "=== Helm install complete (kubectl provided by k3s symlink) ==="
