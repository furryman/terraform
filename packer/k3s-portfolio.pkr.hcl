# Packer configuration for the fuhriman.org k3s portfolio AMI.
#
# Builds an Amazon Linux 2023 ARM (Graviton) image with k3s, helm, and kubectl
# pre-installed. The image is consumed by `tf-modules/aws-k3s/main.tf` via an
# AMI lookup filtered on tag `ManagedBy=Packer` + `Cluster=fuhriman-k3s`.
#
# Build locally:   packer init . && packer validate . && packer build .
# Build in CI:     see .github/workflows/build-ami.yml in this repo (Phase 7.3).
#
# All bootstrap is declarative and baked into the AMI: k3s server config
# at /etc/rancher/k3s/config.yaml, and helm-controller manifests at
# /var/lib/rancher/k3s/server/manifests/ that install ArgoCD and the
# App-of-Apps Application at first boot. No user_data script needed.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

# --- Variables ----------------------------------------------------------------

variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region for the AMI build and final image."
}

variable "instance_type" {
  type        = string
  default     = "t4g.small"
  description = "Builder instance type. Match the runtime instance type so binary compatibility is verified during build."
}

variable "ami_name_prefix" {
  type        = string
  default     = "fuhriman-k3s"
  description = "Prefix for the resulting AMI name."
}

variable "k3s_version" {
  type        = string
  default     = "v1.36.1+k3s1"
  description = "Pinned k3s version. Bump explicitly; do not float."
}

variable "helm_version" {
  type        = string
  default     = "v3.15.4"
  description = "Pinned Helm version."
}

variable "kubectl_version" {
  type        = string
  default     = "v1.36.1"
  description = "Pinned kubectl version. Should match k3s minor."
}

variable "git_sha" {
  type        = string
  default     = "local"
  description = "Set by CI to the commit SHA of the packer/ tree; tags the AMI for traceability."
}

# --- Locals -------------------------------------------------------------------

locals {
  # AMI name is timestamped + git-sha-tagged for uniqueness and traceability.
  # Format: fuhriman-k3s-20260522-031415-abc1234
  ami_name = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}-${var.git_sha}"

  common_tags = {
    Name        = local.ami_name
    ManagedBy   = "Packer"
    Cluster     = "fuhriman-k3s"
    Version     = var.git_sha
    K3sVersion  = var.k3s_version
    HelmVersion = var.helm_version
    BuildDate   = formatdate("YYYY-MM-DD", timestamp())
  }
}

# --- Source: AL2023 ARM, EBS-backed ------------------------------------------

source "amazon-ebs" "k3s" {
  region          = var.aws_region
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "k3s ${var.k3s_version} + helm ${var.helm_version} on AL2023 ARM. Built ${formatdate("YYYY-MM-DD", timestamp())}."

  # Source AMI: latest AL2023 ARM (standard variant), EBS-backed, HVM.
  # The `*-2023.*-*-arm64` pattern excludes ECS-optimized (al2023-ami-ecs-*)
  # and minimal (al2023-ami-minimal-*) variants that ship with larger snapshots
  # or stripped-down packages.
  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-arm64"
      virtualization-type = "hvm"
      architecture        = "arm64"
      root-device-type    = "ebs"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username = "ec2-user"

  # Enforce IMDSv2 on the builder instance (matches the runtime SG hardening).
  imds_support = "v2.0"

  # 20 GB gp3, encrypted — matches the runtime config in tf-modules/aws-k3s.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags          = local.common_tags
  snapshot_tags = local.common_tags
  run_tags = {
    Name      = "packer-build-${local.ami_name}"
    ManagedBy = "Packer"
    Cluster   = "fuhriman-k3s"
  }
}

# --- Build --------------------------------------------------------------------

build {
  name    = "k3s-portfolio"
  sources = ["source.amazon-ebs.k3s"]

  # Wait for cloud-init to finish so any first-boot AL2023 work doesn't race
  # against our installs.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '=== Waiting for cloud-init to complete ==='",
      "sudo cloud-init status --wait || true",
      # Skip `dnf update -y` — AL2023 has a long-standing curl-minimal /
      # curl-full conflict that aborts the update. Just install what we need.
      "echo '=== Installing build-time dependencies ==='",
      "sudo dnf install -y --quiet jq tar gzip ca-certificates",
    ]
  }

  # k3s binary install — does NOT start the service. user_data.sh starts it
  # at runtime with instance-specific flags (--tls-san=<public-ip>).
  provisioner "shell" {
    script = "scripts/install-k3s.sh"
    environment_vars = [
      "K3S_VERSION=${var.k3s_version}",
    ]
  }

  # Helm + kubectl binaries + helm repo cache.
  provisioner "shell" {
    script = "scripts/install-helm.sh"
    environment_vars = [
      "HELM_VERSION=${var.helm_version}",
      "KUBECTL_VERSION=${var.kubectl_version}",
    ]
  }

  # Stage declarative bootstrap files into a temp directory; the next
  # `shell` provisioner moves them into root-owned locations.
  provisioner "file" {
    source      = "files/k3s-config.yaml"
    destination = "/tmp/k3s-config.yaml"
  }

  provisioner "file" {
    source      = "files/k3s-manifests"
    destination = "/tmp"
  }

  # Install declarative bootstrap files + enable k3s and ssm-agent so
  # the instance comes up bootstrapped without any user_data script.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '=== Installing declarative bootstrap files ==='",
      "sudo mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/server/manifests",
      "sudo install -m 0600 /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml",
      "sudo install -m 0644 /tmp/k3s-manifests/00-argocd-namespace.yaml /var/lib/rancher/k3s/server/manifests/",
      "sudo install -m 0644 /tmp/k3s-manifests/10-argocd-helm.yaml /var/lib/rancher/k3s/server/manifests/",
      "sudo install -m 0644 /tmp/k3s-manifests/20-app-of-apps.yaml /var/lib/rancher/k3s/server/manifests/",
      "rm -rf /tmp/k3s-config.yaml /tmp/k3s-manifests",
      "echo '=== Enabling k3s and amazon-ssm-agent for first-boot startup ==='",
      "sudo systemctl enable k3s.service amazon-ssm-agent",
    ]
  }

  # Final cleanup to minimize AMI size and avoid identity-bleed across
  # instances launched from this AMI.
  provisioner "shell" {
    inline = [
      "set -euo pipefail",
      "echo '=== Cleaning up ==='",
      "sudo dnf clean all",
      "sudo rm -rf /var/cache/dnf /tmp/*",
      # Reset machine-id so each launched instance generates its own.
      # AL2023 doesn't ship dbus, so skip the /var/lib/dbus symlink fixup.
      "sudo truncate -s 0 /etc/machine-id",
      # Clear bash history.
      "history -c || true",
      "sudo rm -f /home/ec2-user/.bash_history /root/.bash_history",
      "echo '=== AMI build complete ==='",
    ]
  }

  # Post-processor: emit a manifest so CI can capture the AMI ID.
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
    custom_data = {
      git_sha     = var.git_sha
      k3s_version = var.k3s_version
    }
  }
}
