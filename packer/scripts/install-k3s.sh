#!/bin/bash
# Install k3s binary and systemd unit, but DO NOT start the service.
# Runtime `user_data.sh` will start k3s with instance-specific flags
# (--tls-san=<public-ip>, etc).
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.1+k3s1}"

echo "=== Installing k3s ${K3S_VERSION} (binary + systemd unit only) ==="

# INSTALL_K3S_SKIP_START=true   → don't start the service after install
# INSTALL_K3S_SKIP_ENABLE=true  → don't `systemctl enable` it either
# INSTALL_K3S_EXEC sets default args; runtime user_data will append --tls-san.
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
