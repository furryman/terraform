# Terraform Infrastructure for fuhriman.org

This repository contains Terraform configuration to deploy an AWS EKS cluster with ArgoCD for GitOps-based deployments.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      AWS Cloud                           │
│  ┌─────────────────────────────────────────────────┐    │
│  │                    VPC                          │    │
│  │  ┌─────────────────┐  ┌─────────────────────┐   │    │
│  │  │  Public Subnet  │  │   Private Subnet    │   │    │
│  │  │  (NAT Gateway)  │  │   (EKS Nodes)       │   │    │
│  │  └─────────────────┘  └─────────────────────┘   │    │
│  │                                                 │    │
│  │  ┌─────────────────────────────────────────┐   │    │
│  │  │            EKS Cluster                  │   │    │
│  │  │  ┌───────────────────────────────────┐  │   │    │
│  │  │  │  Node Group (2x t3.medium)        │  │   │    │
│  │  │  │  - ArgoCD                         │  │   │    │
│  │  │  │  - cert-manager                   │  │   │    │
│  │  │  │  - ingress-nginx                  │  │   │    │
│  │  │  │  - fuhriman-website               │  │   │    │
│  │  │  └───────────────────────────────────┘  │   │    │
│  │  └─────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.5.0
3. **kubectl** for cluster management
4. **S3 bucket and DynamoDB table** for Terraform state (see Backend Setup)

## Backend Setup

Before running Terraform, create the required AWS resources for state management:

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

## Deployment

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

## Configure kubectl

After deployment, configure kubectl to access the cluster:

```bash
aws eks update-kubeconfig --region us-west-2 --name fuhriman-eks
```

## Module Structure

```
terraform/
├── tf-modules/
│   ├── aws-vpc/        # VPC, subnets, NAT Gateway, route tables
│   ├── aws-eks/        # EKS cluster, node group, IAM roles
│   └── helm-argocd/    # ArgoCD and argocd-apps Helm releases
├── main.tf             # Root module composition
├── variables.tf        # Input variables
├── outputs.tf          # Output values
├── providers.tf        # Provider configuration
├── backend.tf          # S3 backend configuration
└── README.md
```

## Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | `us-west-2` |
| `cluster_name` | EKS cluster name | `fuhriman-eks` |
| `cluster_version` | Kubernetes version | `1.29` |
| `node_instance_types` | EC2 instance types | `["t3.medium"]` |
| `node_desired_size` | Number of nodes | `2` |

## Outputs

| Output | Description |
|--------|-------------|
| `cluster_endpoint` | EKS API server endpoint |
| `configure_kubectl` | Command to configure kubectl |
| `argocd_namespace` | ArgoCD namespace |

## Access ArgoCD UI

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward to access UI locally
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access at https://localhost:8080
# Username: admin
# Password: (from command above)
```

## Cleanup

```bash
terraform destroy
```
