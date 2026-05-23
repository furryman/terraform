#!/bin/bash
# Install Helm + kubectl binaries and pre-populate the Helm repo cache so
# `helm install` at runtime doesn't have to fetch chart indexes for the first time.
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-v3.15.4}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.4}"

# Detect architecture (arm64 for t4g, amd64 for t3).
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

echo "=== Installing kubectl ${KUBECTL_VERSION} (${ARCH_SUFFIX}) ==="
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_SUFFIX}/kubectl" \
    -o "${TMPDIR}/kubectl"
sudo install -m 0755 "${TMPDIR}/kubectl" /usr/local/bin/kubectl
kubectl version --client

echo "=== Priming Helm repo cache ==="
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add jetstack https://charts.jetstack.io
helm repo update

echo "=== Helm + kubectl install complete ==="
