# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
terraform init          # Initialize providers and modules (state in S3)
terraform plan          # Preview changes
terraform apply         # Apply infrastructure changes
terraform destroy       # Tear down all resources
terraform fmt           # Format .tf files
terraform validate      # Validate configuration syntax
```

Admin access (SSM-only — no SSH, no public k8s API):

```bash
# Interactive shell
aws ssm start-session --target $(terraform output -raw instance_id) --profile portfolio --region us-west-2

# kubectl tunnel (run in Terminal A, leave open)
aws ssm start-session --target $(terraform output -raw instance_id) --document-name AWS-StartPortForwardingSession --parameters portNumber=6443,localPortNumber=6443 --profile portfolio --region us-west-2

# In Terminal B (after one-time kubeconfig retrieval — see kubeconfig_retrieval_command output):
KUBECONFIG=~/.kube/portfolio-config kubectl get nodes
```

Trigger a Packer AMI rebuild:

```bash
gh workflow run build-ami.yml -f reason="<why>" --ref main      # via workflow_dispatch
git tag packer-v1.0.0 && git push origin packer-v1.0.0          # via tag
```

## Architecture

AWS k3s infrastructure for **fuhriman.org**, deployed to **us-west-2** on a single **t4g.medium (Graviton ARM)** instance behind an Elastic IP. Three custom Terraform modules compose the AWS foundation; the cluster workloads are managed by ArgoCD via the App-of-Apps pattern from sibling repos.

```text
aws-vpc → aws-k3s → aws-dns
            │
            └── runtime bootstrap (~60 s) → ArgoCD (chart 9.5.15)
                    │
                    └── App-of-Apps (https://github.com/furryman/argocd-app-of-apps.git)
                            ├── cert-manager       (Let's Encrypt + gatewayHTTPRoute solver)
                            ├── envoy-gateway      (Gateway API; replaces ingress-nginx)
                            ├── external-dns       (Route53 from HTTPRoute hostnames)
                            └── fuhriman-website   (Next.js portfolio)
```

- **aws-vpc** — VPC (10.0.0.0/16), one public subnet, single AZ. No NAT Gateway (cost optimization). Misleading 2-AZ slicing dropped in Phase 1; subnet count honest.
- **aws-k3s** — Single EC2 instance (t4g.medium, ARM) running k3s. Instance launched from a **Packer-built AMI** (k3s, helm, ssm-agent, helm repo cache pre-baked). `user_data.sh` is ~55 lines of runtime-only bootstrap. Elastic IP attached for stable public address. SSM Session Manager is the **only** admin path — ports 22 (SSH) and 6443 (k8s API) are not exposed.
- **aws-dns** — Single public Route53 hosted zone for `fuhriman.org`. `external-dns` in-cluster manages records from `HTTPRoute` resources (and the Gateway's annotation). Squarespace is the registrar only; NS records delegate to Route53.

Root module (`main.tf`) wires the three modules together, defines:
- A `local.tags` block with just `Cluster=<cluster_name>` (other tags come from provider `default_tags`).
- The IAM policy granting ExternalDNS Route53 record management on the public zone, attached to the k3s instance role.
- The OIDC trust + role for GitHub Actions Packer builds.

`budget.tf` creates a $40/mo AWS budget alert (bumped from $25 in Phase 3.5 to accommodate t4g.medium). `dlm.tf` creates the monthly EBS snapshot lifecycle policy (retain 3). `oidc.tf` provisions the GitHub OIDC provider + the `github-actions-packer` IAM role with least-privilege EC2 permissions.

### Routing & TLS

Traffic flows:

```text
Browser → Route53 → EIP 52.37.95.130 → Envoy Gateway data plane (klipper-lb)
                                              │
                                              ▼
                          Gateway "public" (envoy-gateway-system, HTTPS terminate)
                              │
                              ├── HTTPRoute fuhriman-website-fuhriman-chart  (fuhriman.org, www.fuhriman.org)
                              └── HTTPRoute argocd-server                    (argocd.fuhriman.org)
```

- **No `Ingress` resources anywhere.** `ingress-nginx` was removed entirely in Phase 4 PR-B.
- **TLS cert** is a single multi-SAN `Certificate` in `envoy-gateway-system` (named `fuhriman-tls`), covering `fuhriman.org`, `www.fuhriman.org`, `argocd.fuhriman.org`. cert-manager issues via Let's Encrypt HTTP-01 using the `gatewayHTTPRoute` solver against the public Gateway.
- **ArgoCD UI** at `https://argocd.fuhriman.org` (chart 9.5.15, `--insecure` so TLS terminates at the Gateway, not the server).

### In-cluster fuhriman.org resolution (deferred)

`coredns-custom` is **not yet deployed**. Pod-to-fuhriman.org currently relies on the public DNS path + EIP. This works for the website but means cert-manager's HTTP-01 self-checks hairpin out through the public IP. Acceptable while the cert is valid (90 days from issuance); a Phase 4 follow-up will add a CoreDNS rewrite ConfigMap that resolves in-cluster lookups to the Envoy Gateway's ClusterIP.

## State Backend

S3 + native `use_lockfile` locking (Terraform 1.15+). No DynamoDB lock table — that pattern is deprecated. Bucket: `s3://fuhriman-terraform-state/k3s/terraform.tfstate`. Versioning + SSE + block-public-access on.

## Provider Configuration

Only the AWS provider is configured in `providers.tf`. Pinned to `~> 6.31`. Default tags applied via `default_tags`: Environment, ManagedBy, Project. Per-resource `Cluster` and `Name` tags come from `local.tags` and `merge(var.tags, {Name=...})` patterns. No Kubernetes or Helm providers — ArgoCD is installed by `user_data.sh` and all cluster workloads are managed by ArgoCD via the App-of-Apps repo.

## Key Constraints

- Terraform >= 1.15.0 required (for `use_lockfile`).
- AWS provider `~> 6.31`.
- Instance is t4g.medium (4GB RAM, ARM Graviton). Phase 3.5 sized up from t3.small (2GB) because Envoy Gateway + ArgoCD chart 9.x didn't fit.
- IMDSv2 enforced (`http_tokens=required`), `http_put_response_hop_limit=2`.
- AMI is Packer-built (tagged `ManagedBy=Packer` + `Cluster=fuhriman-k3s`); `most_recent=true` lookup picks the latest.
- `user_data_replace_on_change = true` — any change to `user_data.sh` forces instance replacement.
- SSH public key not used; no `aws_key_pair` resource.
- Domain `fuhriman.org` delegated from Squarespace to Route53 via NS records (manual one-time step).
- ArgoCD chart 9.5.15; argocd-apps chart 1.6.2; cert-manager chart 1.14.0; envoy-gateway chart v1.3.0; external-dns chart 1.15.0.
- Multi-arch (`linux/amd64,linux/arm64`) images required for any workload — `fuhriman-website`'s CI builds both.

## Sibling repos

- `argocd-app-of-apps` — Helm chart that declares ArgoCD `Application` resources for the cluster workloads (sync wave order: cert-manager → envoy-gateway + external-dns → fuhriman-website + argocd HTTPRoute).
- `eks-helm-charts` — chart sources consumed by app-of-apps Applications: `cert-manager`, `envoy-gateway` (includes GatewayClass + Gateway + Certificate + argocd HTTPRoute templates), `external-dns`, `fuhriman-chart`. Note: name is vestigial — deploy target is k3s, not EKS.
- `fuhriman-website` — Next.js portfolio app. CI publishes a multi-arch image to Docker Hub and auto-bumps the image tag in `eks-helm-charts/fuhriman-chart/values.yaml`.

## Recent design history

See `docs/plans/2026-05-22-modern-portfolio-architecture.md` for the full design doc (assumption challenges, decision log, phased plan) and `docs/plans/2026-05-22-modern-portfolio-architecture-manual-steps.md` for the operator checklist. Both are uncommitted scratchpads — the deployed state IS the source of truth; the docs describe the journey.
