# Route53 Split-Horizon + ArgoCD Ingress Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the fragile iptables hairpin NAT hack with Route53 split-horizon DNS, add an Elastic IP, expose ArgoCD at `argocd.fuhriman.org` via ingress-nginx with Let's Encrypt TLS, and grant cert-manager DNS-01 permissions via IAM.

**Architecture:** Two Route53 hosted zones (public + private) for `fuhriman.org`. Public zone resolves to the EIP for external traffic. Private zone (VPC-associated) resolves to the EC2 private IP so pods never hit the public IP. ArgoCD moves from NodePort 30443 to an Ingress on port 443. cert-manager uses ambient EC2 credentials for DNS-01 challenges.

**Tech Stack:** Terraform (HCL), AWS Route53, AWS EIP, AWS IAM, k3s, ArgoCD, cert-manager, ingress-nginx

---

### Task 1: Create the `aws-dns` module

**Files:**
- Create: `tf-modules/aws-dns/main.tf`
- Create: `tf-modules/aws-dns/variables.tf`
- Create: `tf-modules/aws-dns/outputs.tf`

**Step 1: Create `tf-modules/aws-dns/variables.tf`**

```hcl
variable "domain_name" {
  description = "Domain name for hosted zones"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to associate with the private hosted zone"
  type        = string
}

variable "instance_public_ip" {
  description = "EC2 public IP (EIP) for public DNS records"
  type        = string
}

variable "instance_private_ip" {
  description = "EC2 private IP for private DNS records"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
```

**Step 2: Create `tf-modules/aws-dns/main.tf`**

```hcl
# Route53 Split-Horizon DNS
# Public zone for external clients, private zone for in-VPC resolution

# Public hosted zone
resource "aws_route53_zone" "public" {
  name    = var.domain_name
  comment = "Public hosted zone for ${var.domain_name}"

  tags = merge(var.tags, {
    Name = "${var.domain_name}-public"
  })
}

# Private hosted zone (associated with VPC)
resource "aws_route53_zone" "private" {
  name    = var.domain_name
  comment = "Private hosted zone for ${var.domain_name} - hairpin NAT avoidance"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(var.tags, {
    Name = "${var.domain_name}-private"
  })
}

# --- Public records (resolve to EIP) ---

resource "aws_route53_record" "public_apex" {
  zone_id = aws_route53_zone.public.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [var.instance_public_ip]
}

resource "aws_route53_record" "public_www" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [var.instance_public_ip]
}

resource "aws_route53_record" "public_argocd" {
  zone_id = aws_route53_zone.public.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [var.instance_public_ip]
}

# --- Private records (resolve to EC2 private IP) ---

resource "aws_route53_record" "private_apex" {
  zone_id = aws_route53_zone.private.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 60
  records = [var.instance_private_ip]
}

resource "aws_route53_record" "private_www" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [var.instance_private_ip]
}

resource "aws_route53_record" "private_argocd" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [var.instance_private_ip]
}
```

**Step 3: Create `tf-modules/aws-dns/outputs.tf`**

```hcl
output "public_zone_id" {
  description = "Route53 public hosted zone ID"
  value       = aws_route53_zone.public.zone_id
}

output "public_zone_name_servers" {
  description = "NS records to configure at Squarespace registrar"
  value       = aws_route53_zone.public.name_servers
}

output "private_zone_id" {
  description = "Route53 private hosted zone ID"
  value       = aws_route53_zone.private.zone_id
}
```

**Step 4: Commit**

```bash
git add tf-modules/aws-dns/
git commit -m "feat: add aws-dns module with Route53 split-horizon zones"
```

---

### Task 2: Add Elastic IP to `aws-k3s` module

**Files:**
- Modify: `tf-modules/aws-k3s/main.tf`
- Modify: `tf-modules/aws-k3s/outputs.tf`

**Step 1: Add EIP resource to `tf-modules/aws-k3s/main.tf`**

Add after the `aws_instance.k3s` resource block (after line 151):

```hcl
# Elastic IP for stable public address (free while attached)
resource "aws_eip" "k3s" {
  instance = aws_instance.k3s.id
  domain   = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-k3s-eip"
  })
}
```

**Step 2: Add `instance_private_ip` and `eip_public_ip` outputs to `tf-modules/aws-k3s/outputs.tf`**

Add at the end of the file:

```hcl
output "instance_private_ip" {
  description = "The private IP of the k3s instance"
  value       = aws_instance.k3s.private_ip
}

output "eip_public_ip" {
  description = "The Elastic IP attached to the k3s instance"
  value       = aws_eip.k3s.public_ip
}
```

**Step 3: Update existing outputs that reference `aws_instance.k3s.public_ip` to use the EIP instead**

In `tf-modules/aws-k3s/outputs.tf`, change every occurrence of `aws_instance.k3s.public_ip` to `aws_eip.k3s.public_ip`. This affects:
- `instance_public_ip` (line 7)
- `ssh_command` (line 23)
- `kubeconfig_command` (line 28)
- `kubeconfig_setup` (lines 34-37)
- `argocd_url` (line 43)
- `argocd_password_command` (line 48)
- `website_urls` (line 58)

**Step 4: Update `argocd_url` output to use the domain name**

Replace the `argocd_url` output:

```hcl
output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = "https://argocd.fuhriman.org"
}
```

**Step 5: Commit**

```bash
git add tf-modules/aws-k3s/main.tf tf-modules/aws-k3s/outputs.tf
git commit -m "feat: add Elastic IP, update outputs to use EIP"
```

---

### Task 3: Add IAM policy for cert-manager Route53 access

**Files:**
- Modify: `tf-modules/aws-k3s/main.tf`
- Modify: `tf-modules/aws-k3s/variables.tf`

**Step 1: Add `route53_zone_id` variable to `tf-modules/aws-k3s/variables.tf`**

Add at the end of the file:

```hcl
variable "route53_zone_id" {
  description = "Route53 public hosted zone ID for cert-manager DNS-01 challenges"
  type        = string
  default     = ""
}
```

**Step 2: Add IAM policy and attachment to `tf-modules/aws-k3s/main.tf`**

Add after the `aws_iam_role_policy_attachment.ssm` resource (after line 112):

```hcl
# Route53 policy for cert-manager DNS-01 challenges
resource "aws_iam_policy" "cert_manager_route53" {
  count = var.route53_zone_id != "" ? 1 : 0

  name        = "${var.cluster_name}-cert-manager-route53"
  description = "Allows cert-manager to manage Route53 DNS-01 challenges"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CertManagerRoute53GetChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid      = "CertManagerRoute53RecordSets"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Sid    = "CertManagerRoute53ListZones"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cert_manager_route53" {
  count = var.route53_zone_id != "" ? 1 : 0

  policy_arn = aws_iam_policy.cert_manager_route53[0].arn
  role       = aws_iam_role.k3s.name
}
```

**Step 3: Commit**

```bash
git add tf-modules/aws-k3s/main.tf tf-modules/aws-k3s/variables.tf
git commit -m "feat: add IAM policy for cert-manager Route53 DNS-01"
```

---

### Task 4: Remove NodePort 30443 security group rule

**Files:**
- Modify: `tf-modules/aws-k3s/main.tf`

**Step 1: Delete the ArgoCD NodePort ingress block**

In `tf-modules/aws-k3s/main.tf`, delete lines 71-77:

```hcl
  ingress {
    description = "ArgoCD NodePort"
    from_port   = 30443
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
```

**Step 2: Commit**

```bash
git add tf-modules/aws-k3s/main.tf
git commit -m "feat: remove ArgoCD NodePort 30443 SG rule, now via ingress"
```

---

### Task 5: Remove hairpin NAT hack from `user_data.sh`

**Files:**
- Modify: `tf-modules/aws-k3s/user_data.sh`

**Step 1: Delete the `iptables-nft` install line**

Delete line 17:

```bash
dnf install -y iptables-nft
```

**Step 2: Delete the entire hairpin NAT section**

Delete lines 92-113 (everything from the `# Hairpin NAT fix` comment through the two `iptables` commands):

```bash
# Hairpin NAT fix: pods can't reach the instance's own public IP because the
# VPC router won't loop packets back. We wait for ingress-nginx (deployed by
# ArgoCD) then jump pod-CIDR traffic destined for the public IP directly into
# kube-proxy's KUBE-EXT chains, which DNAT to the ingress-nginx pod.
echo "Waiting for ingress-nginx to be deployed by ArgoCD..."
until /usr/local/bin/kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; do
  sleep 5
done

# Wait for kube-proxy to create LoadBalancer iptables rules (lags behind service creation)
echo "Waiting for kube-proxy LoadBalancer rules..."
until iptables -t nat -L KUBE-SERVICES -n 2>/dev/null | grep -q "ingress-nginx-controller:http loadbalancer"; do
  sleep 2
done

# Discover kube-proxy's KUBE-EXT chain names for the LoadBalancer service
HTTP_CHAIN=$(iptables -t nat -L KUBE-SERVICES -n | grep "ingress-nginx-controller:http loadbalancer" | awk '{print $1}')
HTTPS_CHAIN=$(iptables -t nat -L KUBE-SERVICES -n | grep "ingress-nginx-controller:https loadbalancer" | awk '{print $1}')

echo "Configuring hairpin NAT fix (public=$PUBLIC_IP, http=$HTTP_CHAIN, https=$HTTPS_CHAIN)..."
iptables -t nat -A PREROUTING -s 10.42.0.0/16 -d "$PUBLIC_IP" -p tcp --dport 80 -j "$HTTP_CHAIN"
iptables -t nat -A PREROUTING -s 10.42.0.0/16 -d "$PUBLIC_IP" -p tcp --dport 443 -j "$HTTPS_CHAIN"
```

**Step 3: Update ArgoCD Helm install to remove NodePort config**

In `user_data.sh`, change the ArgoCD Helm install command. Replace:

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "${argocd_chart_version}" \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttps=30443 \
  --wait --timeout 300s
```

With:

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "${argocd_chart_version}" \
  --set server.extraArgs[0]="--insecure" \
  --wait --timeout 300s
```

The `--insecure` flag tells ArgoCD server to not terminate TLS itself (ingress-nginx handles TLS). The service type defaults to ClusterIP which is correct for Ingress-based access.

**Step 4: Commit**

```bash
git add tf-modules/aws-k3s/user_data.sh
git commit -m "feat: remove hairpin NAT hack, configure ArgoCD for ingress"
```

---

### Task 6: Wire modules together in root `main.tf`

**Files:**
- Modify: `main.tf`
- Modify: `variables.tf`
- Modify: `outputs.tf`

**Step 1: Add `domain_name` variable to `variables.tf`**

Add at the end of the file:

```hcl
variable "domain_name" {
  description = "Domain name for Route53 hosted zones"
  type        = string
  default     = "fuhriman.org"
}
```

**Step 2: Add dns module and update k3s module in `main.tf`**

Replace the entire `main.tf` with:

```hcl
# Main Terraform Configuration
# Orchestrates VPC, k3s, and DNS modules

locals {
  tags = {
    Environment = var.environment
    Cluster     = var.cluster_name
    ManagedBy   = "Terraform"
  }
}

# VPC Module
module "vpc" {
  source = "./tf-modules/aws-vpc"

  cluster_name = var.cluster_name
  vpc_cidr     = var.vpc_cidr
  tags         = local.tags
}

# k3s Module
module "k3s" {
  source = "./tf-modules/aws-k3s"

  cluster_name         = var.cluster_name
  vpc_id               = module.vpc.vpc_id
  subnet_id            = module.vpc.public_subnet_id
  instance_type        = var.instance_type
  volume_size          = var.volume_size
  ssh_public_key       = var.ssh_public_key
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  app_of_apps_repo_url = var.app_of_apps_repo_url
  argocd_chart_version = var.argocd_chart_version
  route53_zone_id      = module.dns.public_zone_id
  tags                 = local.tags

  depends_on = [module.vpc]
}

# DNS Module (Route53 split-horizon)
module "dns" {
  source = "./tf-modules/aws-dns"

  domain_name         = var.domain_name
  vpc_id              = module.vpc.vpc_id
  instance_public_ip  = module.k3s.eip_public_ip
  instance_private_ip = module.k3s.instance_private_ip
  tags                = local.tags

  depends_on = [module.k3s]
}
```

**Step 3: Update `outputs.tf`**

Replace the entire `outputs.tf` with:

```hcl
output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "instance_id" {
  description = "The EC2 instance ID running k3s"
  value       = module.k3s.instance_id
}

output "instance_public_ip" {
  description = "The Elastic IP of the k3s instance"
  value       = module.k3s.eip_public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the k3s instance"
  value       = module.k3s.ssh_command
}

output "kubeconfig_command" {
  description = "Command to retrieve kubeconfig from the instance"
  value       = module.k3s.kubeconfig_command
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = module.k3s.argocd_url
}

output "nameservers" {
  description = "Route53 NS records to configure at Squarespace"
  value       = module.dns.public_zone_name_servers
}

output "route53_public_zone_id" {
  description = "Route53 public hosted zone ID (needed for cert-manager ClusterIssuer)"
  value       = module.dns.public_zone_id
}
```

**Step 4: Run `terraform fmt` and `terraform validate`**

```bash
terraform fmt -recursive
terraform validate
```

Expected: All files formatted, validation passes.

**Step 5: Commit**

```bash
git add main.tf variables.tf outputs.tf
git commit -m "feat: wire Route53 DNS module, add domain_name var, update outputs"
```

---

### Task 7: Validate with `terraform plan`

**Step 1: Run terraform init to pick up the new module**

```bash
terraform init
```

Expected: "Terraform has been successfully initialized!"

**Step 2: Run terraform plan**

```bash
terraform plan
```

Expected: Plan shows new resources to create:
- `aws_route53_zone.public`
- `aws_route53_zone.private`
- 6x `aws_route53_record`
- `aws_eip.k3s`
- `aws_iam_policy.cert_manager_route53`
- `aws_iam_role_policy_attachment.cert_manager_route53`

And changes to:
- Security group (remove NodePort 30443 rule)

Note: There is a circular dependency between `k3s` and `dns` modules (dns needs k3s EIP, k3s needs dns zone_id for IAM). This is resolved by the `count` guard on the IAM policy — on first apply, `route53_zone_id` will be empty string, so the IAM resources are skipped. After `dns` module creates the zone, a second apply (or use of `-target`) will create the IAM policy. Alternatively, we can break the cycle by moving IAM to the dns module or root module.

**If circular dependency is an issue**, restructure Task 3 to put the IAM policy in the root module instead, referencing `module.dns.public_zone_id` directly. This avoids passing the zone_id into k3s at all.

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: resolve any plan issues"
```

---

### Task 8: Update CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

Update the Architecture section to reflect:
- New `aws-dns` module in the module chain: `aws-vpc → aws-k3s → aws-dns`
- Route53 split-horizon DNS replaces iptables hairpin NAT
- ArgoCD accessible at `https://argocd.fuhriman.org` via ingress-nginx
- Elastic IP for stable public address
- cert-manager DNS-01 via Route53 ambient credentials
- Remove the Hairpin NAT section (replaced by Route53 explanation)
- Add manual step: configure Squarespace nameservers to Route53 NS records

**Step 2: Update README.md**

Update to reflect new DNS architecture, ArgoCD URL, nameserver setup instructions, and remove hairpin NAT troubleshooting.

**Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update architecture docs for Route53 + ArgoCD ingress"
```

---

### Task 9 (Separate repo): ArgoCD app-of-apps changes

> This task is in the `argocd-app-of-apps` repository, NOT this Terraform repo.

**Files to create/modify in `argocd-app-of-apps` repo:**

**Step 1: Add cert-manager ClusterIssuer**

Create `cluster-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: adamdfuhriman@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          route53:
            region: us-west-2
        selector:
          dnsZones:
            - "fuhriman.org"
```

**Step 2: Update cert-manager Helm values to enable ambient credentials**

In your cert-manager Application or values file, add:

```yaml
extraArgs:
  - "--issuer-ambient-credentials=true"
  - "--cluster-issuer-ambient-credentials=true"
```

**Step 3: Add ArgoCD Ingress manifest**

Create `argocd-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.fuhriman.org
      secretName: argocd-server-tls
  rules:
    - host: argocd.fuhriman.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

**Step 4: Commit and push in the app-of-apps repo**

```bash
git add cluster-issuer.yaml argocd-ingress.yaml
git commit -m "feat: add ArgoCD ingress + cert-manager DNS-01 ClusterIssuer"
git push
```

---

## Deployment Order

1. Tasks 1-6: All Terraform changes (can be done in sequence, one commit each)
2. Task 7: `terraform init && terraform plan` to validate
3. `terraform apply` to create infrastructure
4. Copy NS records from output, update Squarespace nameservers
5. Wait for DNS propagation (1-4 hours)
6. Task 9: Push app-of-apps changes (ArgoCD auto-syncs)
7. Verify: `curl -I https://argocd.fuhriman.org` returns valid TLS cert
8. Task 8: Update docs
