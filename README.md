# Terraform Infrastructure for fuhriman.org

This repository contains Terraform configuration to deploy a lightweight k3s Kubernetes cluster on AWS with ArgoCD for GitOps-based deployments.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                AWS Cloud                                    │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                          VPC (10.0.0.0/16)                           │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                     Public Subnet (10.0.1.0/24)                │  │  │
│  │  │                                                                │  │  │
│  │  │  ┌──────────────────────────────────────────────────────────┐  │  │  │
│  │  │  │  EC2 t3.small (k3s)                                     │  │  │  │
│  │  │  │                                                         │  │  │  │
│  │  │  │  ┌─────────────┐ ┌─────────────┐ ┌──────────────────┐  │  │  │  │
│  │  │  │  │cert-manager │ │ingress-nginx│ │fuhriman-website  │  │  │  │  │
│  │  │  │  │(Let's Enc.) │ │(ServiceLB)  │ │(Next.js)         │  │  │  │  │
│  │  │  │  └─────────────┘ └─────────────┘ └──────────────────┘  │  │  │  │
│  │  │  │                                                         │  │  │  │
│  │  │  │  ┌─────────────┐ ┌────────────────────────────────────┐ │  │  │  │
│  │  │  │  │   ArgoCD    │ │iptables: hairpin NAT fix           │ │  │  │  │
│  │  │  │  │  (:30443)   │ │(pod CIDR → kube-proxy KUBE-EXT)   │ │  │  │  │
│  │  │  │  └─────────────┘ └────────────────────────────────────┘ │  │  │  │
│  │  │  └──────────────────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─────────────────────────┐                                                │
│  │  AWS Budget ($25/mo)    │                                                │
│  └─────────────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────────────┘
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
│   └── aws-k3s/        # EC2 instance, k3s, ArgoCD, hairpin NAT (via cloud-init)
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
# Note: Accept the self-signed certificate warning in your browser
```

## Hairpin NAT Fix

AWS VPC doesn't support hairpin NAT — when a pod inside the cluster tries to reach the instance's own public IP, the VPC router won't loop the packet back to the same host. This breaks cert-manager HTTP-01 self-checks and any in-cluster request to `fuhriman.org`.

### How it works

The `user_data.sh` script (run during cloud-init) installs `iptables-nft` and, after ArgoCD deploys ingress-nginx, discovers kube-proxy's KUBE-EXT chain names for the LoadBalancer service. It then adds iptables rules that jump pod CIDR (`10.42.0.0/16`) traffic destined for the public IP directly into those chains, piggy-backing on kube-proxy's existing DNAT-to-pod routing.

```
Pod (10.42.0.x) → public IP:80
  → PREROUTING: matches pod CIDR + public IP
  → jumps to KUBE-EXT chain
  → kube-proxy DNATs to ingress-nginx pod
  → response returns normally
```

### Why not simple DNAT?

iptables DNAT is a terminating target — once it fires, the packet exits the chain. A naive `DNAT --to-destination <private-ip>` would bypass kube-proxy's service routing entirely, landing on port 80 with no listener. Jumping into kube-proxy's own chains ensures the packet follows the same path as external traffic.

## DNS Setup

After deployment, configure DNS records in your domain registrar (Squarespace):

```
Type: A
Host: @
Value: <instance-public-ip>

Type: CNAME
Host: www
Value: fuhriman.org
```

## Certificate Management

Let's Encrypt certificates are automatically managed by cert-manager:
- **Issued**: On first deployment after DNS propagation
- **Valid**: 90 days
- **Auto-renewal**: ~30 days before expiration
- **Domains**: fuhriman.org, www.fuhriman.org
- **Challenge type**: HTTP-01 (hairpin NAT fix enables in-cluster self-check)

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

# Verify hairpin NAT rules are in place
sudo iptables -t nat -L PREROUTING -n | grep KUBE-EXT
```

Common issues:
- **DNS not propagated**: Wait 5-10 minutes after setting DNS records
- **Challenge ingresses not created**: Check ArgoCD sync status
- **Hairpin NAT rules missing**: Check `/var/log/k3s-init.log` for errors; ensure `iptables-nft` was installed

## Cost Estimate

| Component | Free Tier | After Free Tier |
|-----------|-----------|-----------------|
| EC2 t3.small (2GB RAM) | $0 (750 hrs/mo)* | ~$17/mo |
| EBS 20GB gp3 | $0 (30GB free) | ~$1.60/mo |
| Public IPv4 | ~$3.65/mo | ~$3.65/mo |
| **Total** | **~$4/mo*** | **~$22/mo** |

*Note: Free tier applies to t3.micro only. t3.small is not eligible for free tier.
