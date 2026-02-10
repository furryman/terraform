# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
terraform init          # Initialize providers and modules
terraform plan          # Preview changes
terraform apply         # Apply infrastructure changes
terraform destroy       # Tear down all resources
terraform fmt           # Format .tf files
terraform validate      # Validate configuration syntax
```

Configure kubectl after deployment:
```bash
# Copy kubeconfig from instance
scp ec2-user@<instance-ip>:/etc/rancher/k3s/k3s.yaml ./k3s-kubeconfig.yaml
sed -i 's/127.0.0.1/<instance-ip>/g' ./k3s-kubeconfig.yaml
export KUBECONFIG=./k3s-kubeconfig.yaml
```

Access ArgoCD UI:
```bash
# Get admin password
ssh ec2-user@<instance-ip> "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
# Open https://<instance-ip>:30443 — user: admin
```

## Architecture

AWS k3s infrastructure for **fuhriman.org** deployed to **us-west-2**. Two custom modules compose the stack:

```
aws-vpc → aws-k3s
```

- **aws-vpc** — VPC (10.0.0.0/16) with one public subnet, single AZ. No NAT Gateway (cost optimization).
- **aws-k3s** — Single t3.micro EC2 instance running k3s (self-managed Kubernetes). ArgoCD (Helm chart v5.55.0) and App-of-Apps pattern installed via cloud-init user_data, pointing to `https://github.com/furryman/argocd-app-of-apps.git` with auto-sync, prune, and self-heal.

All modules live under `tf-modules/`. Root module (`main.tf`) wires them together, passing VPC outputs into the k3s module. A `budget.tf` file creates a $25/mo AWS budget alert for cost governance.

### Hairpin NAT

AWS VPC doesn't support hairpin NAT — pods can't reach the instance's own public IP because the VPC router won't loop packets back to the same host. This breaks cert-manager HTTP-01 self-checks and any in-cluster request to `fuhriman.org`. The fix in `user_data.sh` waits for ingress-nginx (deployed by ArgoCD), discovers kube-proxy's KUBE-EXT chain names for the LoadBalancer service, then adds iptables rules that jump pod CIDR (`10.42.0.0/16`) traffic destined for the public IP directly into those chains. This piggybacks on kube-proxy's existing DNAT-to-pod routing. Requires `iptables-nft` package (not included in Amazon Linux 2023 by default).

## State Backend

The S3 + DynamoDB backend in `backend.tf` is currently **commented out** — Terraform uses local state. To enable remote state, create the S3 bucket (`fuhriman-terraform-state`) and DynamoDB table (`terraform-state-lock`) per the instructions in README.md, then uncomment the backend block.

## Provider Configuration

Only the AWS provider is configured in `providers.tf`. Default resource tags (Environment, ManagedBy, Project) are applied via the AWS provider. No Kubernetes or Helm providers — ArgoCD is installed via EC2 user_data.

## Key Constraints

- Terraform >= 1.14.0 required
- AWS provider >= 5.0
- Instance is t3.micro (1GB RAM, free tier eligible) — k3s + ArgoCD use ~700MB, leaving ~300MB for workloads
- ArgoCD runs in insecure mode via NodePort on port 30443
- SSH public key required via `ssh_public_key` variable (no default)
- Budget notification email required via `budget_notification_email` variable
