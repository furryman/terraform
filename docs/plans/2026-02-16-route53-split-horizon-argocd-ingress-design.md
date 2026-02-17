# Route53 Split-Horizon DNS + ArgoCD Public Ingress

**Date:** 2026-02-16
**Status:** Approved

## Problem

1. **Hairpin NAT**: AWS VPC won't loop packets back to the same EC2 instance. Pods resolving `fuhriman.org` get the public IP, packets hit the VPC router, and get dropped. Current workaround: iptables rules in `user_data.sh` that jump into kube-proxy's KUBE-EXT chains. This is fragile (breaks on kube-proxy restarts, requires runtime chain discovery).

2. **ArgoCD access**: Currently exposed via NodePort 30443 with self-signed certificate. No DNS name, requires `https://<ip>:30443`.

3. **cert-manager DNS-01 blocked**: Domain is on Squarespace which has no DNS API. HTTP-01 works but DNS-01 (needed for wildcard certs, more reliable) is unavailable.

## Solution

Delegate DNS from Squarespace to Route53. Create split-horizon zones (public + private) so pods resolve to the private IP. Route ArgoCD through ingress-nginx on port 443 with a Let's Encrypt certificate via DNS-01.

## Architecture

```
External client                         Pod (10.42.0.x)
      |                                       |
      v                                       v
Route53 PUBLIC zone                    Route53 PRIVATE zone
  fuhriman.org -> EIP                    fuhriman.org -> 10.0.x.x (private IP)
  argocd.fuhriman.org -> EIP             argocd.fuhriman.org -> 10.0.x.x
      |                                       |
      v                                       v
  EIP -> EC2 -> ingress-nginx           EC2 eth0 -> ingress-nginx
      |                                       |
      v                                       v
  fuhriman.org -> website pod           Same routing, no hairpin needed
  argocd.fuhriman.org -> argocd-server
```

## Components

### 1. New Terraform Module: `tf-modules/aws-dns`

Creates two Route53 hosted zones for `fuhriman.org`:

- **Public zone**: A records for `fuhriman.org`, `www.fuhriman.org`, `argocd.fuhriman.org` -> Elastic IP
- **Private zone**: Same records -> EC2 private IP. Associated with the VPC.

Variables: `domain_name`, `vpc_id`, `instance_public_ip`, `instance_private_ip`, `tags`
Outputs: `public_zone_id`, `public_zone_name_servers`, `private_zone_id`

### 2. Elastic IP (in `aws-k3s` module)

Current setup uses ephemeral public IP that changes on stop/start. Adding `aws_eip` gives a stable IP for Route53 records. Free while attached to a running instance.

### 3. IAM Policy for cert-manager (in `aws-k3s` module)

Attach Route53 permissions to the existing `aws_iam_role.k3s`:
- `route53:GetChange` on `arn:aws:route53:::change/*`
- `route53:ChangeResourceRecordSets` on the public hosted zone
- `route53:ListHostedZones`, `route53:ListHostedZonesByName` on `*`

cert-manager uses ambient credentials (EC2 instance metadata) — no secrets needed.

### 4. ArgoCD Ingress (in `argocd-app-of-apps` repo)

- Ingress resource: host `argocd.fuhriman.org`, TLS via cert-manager
- ArgoCD server: `--insecure` flag (TLS terminates at ingress, not ArgoCD)
- Certificate: DNS-01 ClusterIssuer with Route53

### 5. Remove Hairpin NAT (in `user_data.sh`)

Delete the entire iptables hairpin section:
- `dnf install -y iptables-nft`
- Wait for ingress-nginx
- Discover KUBE-EXT chains
- Add PREROUTING rules

### 6. Security Group Cleanup (in `aws-k3s` module)

Remove NodePort 30443 ingress rule (ArgoCD now goes through port 443 via ingress-nginx).

## Changes by File

| File | Action |
|---|---|
| `tf-modules/aws-dns/main.tf` | **New** — Route53 public + private zones, 6 A records |
| `tf-modules/aws-dns/variables.tf` | **New** — domain_name, vpc_id, IPs, tags |
| `tf-modules/aws-dns/outputs.tf` | **New** — zone IDs, nameservers |
| `tf-modules/aws-k3s/main.tf` | Add EIP, IAM policy, remove NodePort 30443 SG rule |
| `tf-modules/aws-k3s/variables.tf` | Add `route53_zone_id` |
| `tf-modules/aws-k3s/outputs.tf` | Add `instance_private_ip`, `eip_public_ip`, update `argocd_url` |
| `tf-modules/aws-k3s/user_data.sh` | Remove hairpin NAT section |
| `main.tf` | Add `dns` module, wire outputs between modules |
| `variables.tf` | Add `domain_name` variable |
| `outputs.tf` | Add `nameservers` output, update `argocd_url` |

## Changes in argocd-app-of-apps repo (separate PR)

- cert-manager Helm values: `--issuer-ambient-credentials=true`, `--cluster-issuer-ambient-credentials=true`
- ClusterIssuer: DNS-01 solver with Route53
- ArgoCD Ingress manifest with TLS
- ArgoCD server `--insecure` flag

## Cost Impact

- Route53 hosted zone: +$0.50/mo per zone ($1.00 total for public + private)
- Elastic IP: Free while attached to running instance
- Total: ~+$1.00/mo

## Manual Steps After Apply

1. Copy the 4 Route53 NS records from Terraform output
2. In Squarespace: Domains -> fuhriman.org -> DNS Settings -> "Use custom nameservers"
3. Enter the 4 NS records, save
4. Wait 1-4 hours for propagation
5. Verify: `dig fuhriman.org @ns-xxx.awsdns-xx.com` returns the EIP

## Risks

- **DNS propagation downtime**: 1-4 hours where the domain may be unreachable during NS migration
- **Private zone precedence**: Any record needed from within the VPC must exist in the private zone too
- **Memory**: cert-manager uses 30-60MB RAM on the already constrained t3 instance
