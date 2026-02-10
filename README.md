# Terraform Infrastructure for fuhriman.org

This repository contains Terraform configuration to deploy a lightweight k3s Kubernetes cluster on AWS with ArgoCD for GitOps-based deployments.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      AWS Cloud                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │                    VPC                          │    │
│  │  ┌─────────────────────────────────────────┐    │    │
│  │  │            Public Subnet                │    │    │
│  │  │                                         │    │    │
│  │  │  ┌───────────────────────────────────┐  │    │    │
│  │  │  │  EC2 t3.small (k3s)               │  │    │    │
│  │  │  │  - ArgoCD (:30443)                │  │    │    │
│  │  │  │  - App-of-Apps (GitOps)           │  │    │    │
│  │  │  │  - fuhriman-website               │  │    │    │
│  │  │  │  - cert-manager + ingress-nginx   │  │    │    │
│  │  │  └───────────────────────────────────┘  │    │    │
│  │  └─────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────────────┐                            │
│  │  AWS Budget ($25/mo)    │                            │
│  └─────────────────────────┘                            │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.14.0
3. **kubectl** for cluster management
4. **SSH key pair** for EC2 instance access

## Quick Start

```bash
# Initialize Terraform
terraform init

# Create terraform.tfvars with required variables
cat > terraform.tfvars <<'EOF'
ssh_public_key            = "ssh-rsa AAAA... user@host"
budget_notification_email = "you@example.com"
EOF

# Plan and apply
terraform plan
terraform apply
```

## Backend Setup

Before running Terraform, optionally create the required AWS resources for remote state management:

```bash
# Create S3 bucket
aws s3api create-bucket \
  --bucket fuhriman-terraform-state \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket fuhriman-terraform-state \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket fuhriman-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket fuhriman-terraform-state \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-2
```

Then uncomment the backend block in `backend.tf`.

## Configure kubectl

After deployment, retrieve the kubeconfig from the k3s instance:

```bash
# Get the instance IP from Terraform output
terraform output instance_public_ip

# Copy kubeconfig
scp ec2-user@<instance-ip>:/etc/rancher/k3s/k3s.yaml ./k3s-kubeconfig.yaml
sed -i 's/127.0.0.1/<instance-ip>/g' ./k3s-kubeconfig.yaml
export KUBECONFIG=./k3s-kubeconfig.yaml

# Verify
kubectl get nodes
```

## Module Structure

```
terraform/
├── tf-modules/
│   ├── aws-vpc/        # VPC, subnets, Internet Gateway, route tables
│   └── aws-k3s/        # EC2 instance, k3s, ArgoCD (via cloud-init)
├── main.tf             # Root module composition
├── variables.tf        # Input variables
├── outputs.tf          # Output values
├── providers.tf        # AWS provider configuration
├── budget.tf           # AWS budget alert ($25/mo)
├── backend.tf          # S3 backend configuration (commented out)
└── README.md
```

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | `us-west-2` |
| `cluster_name` | Name prefix for resources | `fuhriman-k3s` |
| `instance_type` | EC2 instance type | `t3.small` |
| `volume_size` | Root EBS volume size (GB) | `20` |
| `ssh_public_key` | SSH public key content | *required* |
| `allowed_ssh_cidrs` | CIDRs for SSH/API access | `["0.0.0.0/0"]` |
| `app_of_apps_repo_url` | ArgoCD App-of-Apps repo | `https://github.com/furryman/argocd-app-of-apps.git` |
| `argocd_chart_version` | ArgoCD Helm chart version | `5.55.0` |
| `budget_notification_email` | Email for budget alerts | *required* |

## Outputs

| Output | Description |
|--------|-------------|
| `instance_public_ip` | Public IP of the k3s instance |
| `ssh_command` | SSH command to connect |
| `kubeconfig_command` | Command to retrieve kubeconfig |
| `kubeconfig_setup` | Detailed kubectl setup instructions |
| `argocd_url` | URL to access ArgoCD UI |
| `argocd_password_command` | Command to get ArgoCD password |
| `website_urls` | Production website URLs |

## Access ArgoCD UI

```bash
# Get ArgoCD admin password
ssh ec2-user@<instance-ip> "sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

# Access at https://<instance-ip>:30443
# Username: admin
# Password: (from command above)
```

## Certificate Management & DNS Configuration

### Automated Setup

The deployment automatically configures:

1. **CoreDNS Split-Horizon DNS** - Resolves `fuhriman.org` and `www.fuhriman.org` to the internal ingress-nginx ClusterIP when queried from within the cluster. This solves the hairpin NAT problem for ACME HTTP-01 certificate validation.

2. **Cert-Manager Configuration** - Disables internal self-checks that would fail due to hairpin NAT:
   - `CERT_MANAGER_HTTP01_SELF_CHECK_ENABLED=false`
   - `CERT_MANAGER_HTTP01_SELF_CHECK_NAMESERVERS=8.8.8.8:53,1.1.1.1:53`

3. **Ingress SSL Configuration** - Sets `nginx.ingress.kubernetes.io/ssl-redirect="false"` to allow HTTP-01 ACME challenges while still enforcing HTTPS for regular traffic.

### DNS Setup Required

After deployment, configure DNS records in your domain registrar:

```
Type: A
Host: @
Value: <instance-public-ip>

Type: CNAME
Host: www
Value: fuhriman.org
```

### Certificate Auto-Renewal

Let's Encrypt certificates are automatically managed by cert-manager:
- **Issued**: On first deployment after DNS propagation
- **Valid**: 90 days
- **Auto-renewal**: ~30 days before expiration
- **Domains**: fuhriman.org, www.fuhriman.org

### Troubleshooting Certificates

If certificates fail to issue:

```bash
# Check certificate status
kubectl get certificate -n default

# Check certificate details
kubectl describe certificate fuhriman-tls -n default

# Check ACME challenges
kubectl get challenges -n default

# View cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager --tail=50
```

Common issues:
- **DNS not propagated**: Wait 5-10 minutes after setting DNS records
- **Challenge ingresses not created**: Check ArgoCD sync status
- **403 errors**: Verify CoreDNS configuration includes internal IP mappings

## Cost Estimate

| Component | Free Tier | After Free Tier |
|-----------|-----------|-----------------|
| EC2 t3.small (2GB RAM) | $0 (750 hrs/mo)* | ~$17/mo |
| EBS 20GB gp3 | $0 (30GB free) | ~$1.60/mo |
| Public IPv4 | ~$3.65/mo | ~$3.65/mo |
| **Total** | **~$4/mo*** | **~$22/mo** |

*Note: Free tier applies to t3.micro only. t3.small is not eligible for free tier.
