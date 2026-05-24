#!/bin/bash
# Install k3s binary and systemd unit, but DO NOT start the service.
# Runtime startup is via systemd k3s.service (enabled at Packer time
# in k3s-portfolio.pkr.hcl), which reads /etc/rancher/k3s/config.yaml
# (also baked at Packer time). No user_data script.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.1+k3s1}"

echo "=== Installing k3s ${K3S_VERSION} (binary + systemd unit only) ==="

# INSTALL_K3S_SKIP_START=true   → don't start the service after install
# INSTALL_K3S_SKIP_ENABLE=true  → don't `systemctl enable` it either
# INSTALL_K3S_EXEC default args are overridden at runtime by
# /etc/rancher/k3s/config.yaml (disable=traefik, write-kubeconfig-mode=0644).
curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_SKIP_ENABLE=true \
    INSTALL_K3S_EXEC="server --disable=traefik --write-kubeconfig-mode=644" \
    sh -

echo "=== Verifying k3s binary ==="
/usr/local/bin/k3s --version

# Confirm the unit file exists but is not enabled.
if systemctl is-enabled k3s.service 2>/dev/null | grep -q enabled; then
    echo "ERROR: k3s.service is enabled but should not be (runtime should control start)"
    exit 1
fi

echo "=== k3s install complete ==="
