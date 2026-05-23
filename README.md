# Terraform Infrastructure for fuhriman.org

AWS infrastructure for a k3s + ArgoCD + Gateway API portfolio cluster. Single t4g.medium (Graviton ARM) instance behind an Elastic IP, with all cluster workloads managed declaratively via ArgoCD's App-of-Apps pattern from sibling repos.

## Architecture

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ AWS us-west-2                                                                │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ VPC 10.0.0.0/16 — Public subnet 10.0.1.0/24 (single AZ)                  │ │
│ │                                                                          │ │
│ │ ┌──────────────────────────────────────────────────────────────────────┐ │ │
│ │ │ EC2 t4g.medium (k3s) — EIP 52.37.95.130 — Packer-built AMI           │ │ │
│ │ │                                                                      │ │ │
│ │ │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                  │ │ │
│ │ │  │ cert-manager │ │envoy-gateway │ │ external-dns │                  │ │ │
│ │ │  │ (LE HTTP-01) │ │ (Gateway API)│ │  (Route53)   │                  │ │ │
│ │ │  └──────────────┘ └──────────────┘ └──────────────┘                  │ │ │
│ │ │  ┌──────────────┐ ┌──────────────┐                                   │ │ │
│ │ │  │   ArgoCD     │ │ fuhriman-    │                                   │ │ │
│ │ │  │ (chart 9.x)  │ │ website      │                                   │ │ │
│ │ │  └──────────────┘ └──────────────┘                                   │ │ │
│ │ └──────────────────────────────────────────────────────────────────────┘ │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ Route53 zone fuhriman.org   ──→  ExternalDNS in cluster writes records       │
│ S3 terraform-state          ──→  native use_lockfile (no DynamoDB)           │
│ DLM monthly snapshots × 3   ──→  rolling EBS rollback window                 │
│ Budget alert $40/mo                                                          │
│ IAM OIDC role (github-actions-packer) ──→ workflow builds AMIs               │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS CLI v2** + **Session Manager Plugin** ([install](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).
2. **Terraform** ≥ 1.15.0 (for native S3 backend locking).
3. **kubectl** for cluster management.
4. **gh CLI** for triggering Packer AMI builds.
5. AWS IAM user with broad permissions (the bootstrap; created once via the AWS console or `aws iam create-user`).
6. AWS CLI profile named `portfolio` configured with that user's credentials.

## Quick Start

```bash
# One-time: provision the state bucket
aws s3api create-bucket --bucket fuhriman-terraform-state --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2 --profile portfolio
aws s3api put-bucket-versioning --bucket fuhriman-terraform-state \
  --versioning-configuration Status=Enabled --profile portfolio
aws s3api put-bucket-encryption --bucket fuhriman-terraform-state --profile portfolio \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket fuhriman-terraform-state --profile portfolio \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Configure terraform.tfvars (gitignored)
cat > terraform.tfvars <<'EOF'
budget_notification_email = "you@example.com"
EOF

# Initialize + apply
AWS_PROFILE=portfolio terraform init
AWS_PROFILE=portfolio terraform plan
AWS_PROFILE=portfolio terraform apply
```

After the first apply, output `nameservers` lists the four Route53 NS values — paste them into Squarespace's DNS settings to delegate the domain.

## Module Structure

```text
terraform/
├── tf-modules/
│   ├── aws-vpc/          # VPC, public subnet, IGW, route table
│   ├── aws-k3s/          # EC2 t4g.medium, EIP, SG, IAM role w/ SSM, user_data.sh runtime bootstrap
│   └── aws-dns/          # Route53 public hosted zone for fuhriman.org
├── packer/
│   ├── k3s-portfolio.pkr.hcl   # AMI build config (AL2023 arm64; bakes k3s, helm, ssm-agent, helm repo cache)
│   └── scripts/                # Provisioner scripts
├── .github/workflows/
│   └── build-ami.yml     # OIDC-authenticated Packer build + 3-AMI retention cleanup
├── docs/plans/           # Design + manual-steps docs from the 2026-05-22 architecture refactor
├── main.tf               # Root module composition + IAM policies (ExternalDNS Route53, GitHub Actions OIDC)
├── variables.tf          # Input variables with validation blocks
├── outputs.tf            # nameservers, instance_id, SSM commands, kubeconfig retrieval, argocd_url, etc.
├── providers.tf          # AWS provider pinned ~> 6.31, default_tags
├── budget.tf             # $40/mo budget alert
├── dlm.tf                # Monthly EBS snapshots × 3 retention
├── oidc.tf               # GitHub Actions OIDC trust + Packer IAM role
└── backend.tf            # S3 backend with use_lockfile=true
```

## Variables

| Variable | Description | Default |
|---|---|---|
| `aws_region` | AWS region | `us-west-2` |
| `environment` | Environment name | `prod` |
| `cluster_name` | Name prefix for resources | `fuhriman-k3s` |
| `vpc_cidr` | VPC CIDR | `10.0.0.0/16` |
| `instance_type` | EC2 instance type | `t4g.medium` |
| `volume_size` | Root EBS volume size (GB) | `20` |
| `app_of_apps_repo_url` | ArgoCD App-of-Apps repo | `https://github.com/furryman/argocd-app-of-apps.git` |
| `argocd_chart_version` | ArgoCD Helm chart version | `9.5.15` |
| `budget_notification_email` | Email for $40/mo budget alert | *required* |
| `domain_name` | Route53 hosted zone domain | `fuhriman.org` |

## Outputs

| Output | Description |
|---|---|
| `instance_id` | EC2 instance ID |
| `instance_public_ip` | Elastic IP attached to the instance |
| `instance_private_ip` | VPC private IP |
| `argocd_url` | `https://argocd.fuhriman.org` |
| `ssm_session_command` | `aws ssm start-session ...` for interactive shell |
| `ssm_port_forward_kubectl_command` | `aws ssm start-session --document-name AWS-StartPortForwardingSession ...` |
| `kubeconfig_retrieval_command` | One-time fetch of `/etc/rancher/k3s/k3s.yaml` via SSM |
| `argocd_password_command` | `kubectl ... get secret argocd-initial-admin-secret ...` |
| `nameservers` | Route53 NS records (paste into Squarespace) |
| `route53_zone_id` | Hosted zone ID |
| `github_actions_packer_role_arn` | OIDC IAM role for AMI builds |

## Admin Workflows

### kubectl via SSM tunnel

```bash
# One-time: fetch kubeconfig (cluster-admin creds; handle with care)
$(terraform output -raw kubeconfig_retrieval_command)

# Each session: open the tunnel in Terminal A
$(terraform output -raw ssm_port_forward_kubectl_command)

# In Terminal B
export KUBECONFIG=~/.kube/portfolio-config
kubectl get nodes
```

### ArgoCD UI

`https://argocd.fuhriman.org` (Let's Encrypt cert). Initial admin password:

```bash
KUBECONFIG=~/.kube/portfolio-config $(terraform output -raw argocd_password_command)
```

### Trigger an AMI rebuild

Tag-based:

```bash
git tag packer-v1.0.0 && git push origin packer-v1.0.0
```

Manual:

```bash
gh workflow run build-ami.yml -f reason="quarterly base AMI refresh" --ref main
```

CI lifecycle keeps the 3 most recent AMIs tagged `ManagedBy=Packer` + `Cluster=fuhriman-k3s`. The Terraform `data "aws_ami"` lookup with `most_recent=true` picks them up automatically; the next `terraform apply` replaces the instance from the new AMI (only if `user_data.sh` also changed, since `user_data_replace_on_change=true` is the trigger).

## Cost (steady state)

| Component | Cost |
|---|---|
| EC2 t4g.medium | ~$24/mo |
| EBS 20 GB gp3 | $1.60 |
| Public IPv4 (EIP, attached) | $3.65 |
| Route53 public zone | $0.50 |
| S3 state + DLM snapshots | ~$1.50 |
| Packer AMI snapshot (~1.5 GB unique) | ~$0.30 |
| **Total** | **~$31/mo** |

Within the $40/mo budget alert.

## Design + Operator Docs

`docs/plans/2026-05-22-modern-portfolio-architecture.md` — full design with decision log, phased plan, and cost analysis.
`docs/plans/2026-05-22-modern-portfolio-architecture-manual-steps.md` — operator checklist for the migration.

Both files are kept in-tree as reference; they describe the journey from the original 2026-02 setup to the current architecture across 8 phases.
