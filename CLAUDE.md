# CLAUDE.md

Guidance for Claude Code working in this repository.

This is the AWS-side infrastructure for **fuhriman.org** — a single-node k3s + ArgoCD + Gateway API cluster running on Graviton ARM, with all in-cluster workloads managed declaratively from sibling repos. Three sibling repos compose with this one: `eks-helm-charts` (chart sources, vestigial name), `argocd-app-of-apps` (parent Application chart), and `fuhriman-website` (the Next.js portfolio).

## Commands

```bash
terraform init                  # Initialize providers, modules, S3 backend
terraform plan                  # Preview changes
terraform apply                 # Apply infrastructure changes
terraform fmt -recursive        # Format .tf files
terraform validate              # Validate configuration syntax
terraform destroy               # Tear down everything
```

Admin access (SSM-only — no SSH, no public k8s API):

```bash
# Interactive shell
aws ssm start-session --target $(terraform output -raw instance_id) \
  --profile portfolio --region us-west-2

# kubectl tunnel (Terminal A — leave it running)
aws ssm start-session --target $(terraform output -raw instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=6443,localPortNumber=6443 \
  --profile portfolio --region us-west-2

# Terminal B (after a one-time `terraform output kubeconfig_retrieval_command` run)
KUBECONFIG=~/.kube/portfolio-config kubectl get nodes
```

If `kubectl` returns `Unauthorized` or "certificate signed by unknown authority", the local kubeconfig is stale — the instance was replaced and k3s regenerated its CA. Re-run `terraform output -raw kubeconfig_retrieval_command | bash` to refresh.

Trigger a Packer AMI rebuild:

```bash
gh workflow run build-ami.yml -f reason="<why>" --ref main      # workflow_dispatch
git tag packer-v1.0.0 && git push origin packer-v1.0.0           # tag-driven
```

## Architecture

AWS k3s infrastructure for **fuhriman.org**, deployed to **us-west-2** on a single **t4g.medium (Graviton ARM)** instance behind an Elastic IP. Three custom Terraform modules compose the AWS foundation; cluster workloads are managed by ArgoCD via the App-of-Apps pattern from the sibling repos.

```text
aws-vpc → aws-k3s → aws-dns
            │
            └── runtime bootstrap (~60 s) → ArgoCD (chart 9.5.15)
                    │
                    └── App-of-Apps (github.com/furryman/argocd-app-of-apps)
                            ├── cert-manager       (Let's Encrypt + gatewayHTTPRoute solver)
                            ├── envoy-gateway      (Gateway API; replaces ingress-nginx)
                            ├── external-dns       (Route53 from HTTPRoute hostnames)
                            └── fuhriman-website   (Next.js portfolio)
```

- **`tf-modules/aws-vpc/`** — VPC (10.0.0.0/16), one public subnet, single AZ. No NAT Gateway (cost). Single-AZ slicing is deliberate; do not "fix" it by introducing multi-AZ data sources.
- **`tf-modules/aws-k3s/`** — Single EC2 instance (`t4g.medium`, ARM) running k3s. Launched from a **Packer-built AMI** that contains everything: k3s binary, systemd units (enabled), helm-controller manifests under `/var/lib/rancher/k3s/server/manifests/` (ArgoCD HelmChart CR + App-of-Apps Application), k3s server config at `/etc/rancher/k3s/config.yaml`, and the ssm-agent (enabled). **No `user_data` script — bootstrap is fully declarative inside the AMI.** Elastic IP attached for stable public address. SSM Session Manager is the **only** admin path — ports 22 (SSH) and 6443 (k8s API) are not exposed.
- **`tf-modules/aws-dns/`** — Single public Route53 hosted zone for `fuhriman.org`. ExternalDNS in-cluster manages records from `HTTPRoute` resources (and the Gateway's annotation). Squarespace is the registrar only; NS records delegate to Route53.

Root module (`main.tf`) wires the three modules together and defines:

- A `local.tags` block with just `Cluster=<cluster_name>` (other tags come from provider `default_tags`).
- The IAM policy granting ExternalDNS Route53 record management on the public zone, attached to the k3s instance role.
- The OIDC trust + role for GitHub Actions Packer builds.

`budget.tf` — $40/mo AWS budget alert. `dlm.tf` — monthly EBS snapshot lifecycle policy (retain 3). `oidc.tf` — GitHub OIDC provider + the `github-actions-packer` IAM role with least-privilege EC2 permissions for Packer.

### Routing & TLS

Traffic flow:

```text
Browser → Route53 → EIP 52.37.95.130 → Envoy Gateway data plane (klipper-lb)
                                              │
                                              ▼
                          Gateway "public" (envoy-gateway-system, HTTPS terminate)
                              │
                              ├── HTTPRoute fuhriman-website  (fuhriman.org, www.fuhriman.org)
                              └── HTTPRoute argocd-server     (argocd.fuhriman.org)
```

- **No `Ingress` resources anywhere.** Routing is Gateway API end to end.
- **TLS cert** is a single multi-SAN `Certificate` in `envoy-gateway-system` (named `fuhriman-tls`), covering `fuhriman.org`, `www.fuhriman.org`, `argocd.fuhriman.org`. cert-manager issues via Let's Encrypt HTTP-01 using the `gatewayHTTPRoute` solver against the public Gateway.
- **ArgoCD UI** at `https://argocd.fuhriman.org` (chart 9.5.15, `--insecure` so TLS terminates at the Gateway, not the server).

### Known deferred work

`coredns-custom` is not yet deployed. Pod-to-`fuhriman.org` resolution hairpins through the public DNS path + EIP. This is fine for the website but means cert-manager's HTTP-01 self-checks egress through the public IP. Acceptable while the cert is valid (90 days). A follow-up will add a CoreDNS rewrite ConfigMap that resolves in-cluster lookups directly to the Envoy Gateway's ClusterIP.

## State Backend

S3 + native `use_lockfile` locking (Terraform 1.15+). **No DynamoDB lock table** — that pattern is deprecated. Bucket: `s3://fuhriman-terraform-state/k3s/terraform.tfstate`. Versioning + SSE + block-public-access on.

## Providers

Only the AWS provider is configured in `providers.tf`. Pinned to `~> 6.31`. Default tags applied via `default_tags`: `Environment`, `ManagedBy`, `Project`. Per-resource `Cluster` and `Name` tags come from `local.tags` and `merge(var.tags, {Name=...})` patterns. **No Kubernetes or Helm providers** — ArgoCD is installed at first boot by k3s's built-in `helm-controller` (reading manifests baked into the AMI at `/var/lib/rancher/k3s/server/manifests/`), and all cluster workloads are managed by ArgoCD via the App-of-Apps repo.

## Packer pipeline

`packer/k3s-portfolio.pkr.hcl` defines the AMI build. Source AMI filter: `al2023-ami-2023.*-arm64` (ARM Graviton). Builder is a transient `t4g.small`. Provisioner scripts in `packer/scripts/`:

- `install-k3s.sh` — bakes the k3s binary at a pinned version.
- `install-helm.sh` — installs helm via the upstream installer, then **`sudo helm repo add`** for the cached repos (so they land in `/root/.config/helm/`, not `ec2-user`'s home).

The lookup in `tf-modules/aws-k3s/main.tf` uses `data.aws_ami.packer_baked` filtered on tags `ManagedBy=Packer` + `Cluster=fuhriman-k3s` with `most_recent=true`. `.github/workflows/build-ami.yml` is OIDC-authenticated (no static AWS credentials), assumes `arn:aws:iam::317369398303:role/github-actions-packer`, and cleans up so only the 3 newest AMIs survive.

Key Packer gotchas captured in the scripts:

- **AL2023 has no `iptables` by default** — install `iptables-nft` if you need it (kube-proxy ships its own internally).
- **AL2023 doesn't ship dbus** — don't try to seed `/var/lib/dbus/machine-id`.
- **`dnf update -y` fails on AL2023** with a curl/curl-minimal package conflict — skip it.
- **Don't install upstream `kubectl`** — it clobbers the k3s symlink at `/usr/local/bin/kubectl`. The k3s symlink does kubeconfig auto-discovery; upstream kubectl does not.

## Key constraints

- Terraform >= **1.15.0** (for `use_lockfile`).
- AWS provider `~> 6.31`.
- Instance is `t4g.medium` (4 GB RAM, ARM Graviton). 2 GB was too small for Envoy Gateway controller + ArgoCD 9.x to coexist comfortably.
- **IMDSv2 enforced** (`http_tokens=required`), `http_put_response_hop_limit=2`.
- AMI is Packer-built (tagged `ManagedBy=Packer` + `Cluster=fuhriman-k3s`); `most_recent=true` picks the latest.
- AMI ID change is the single trigger for instance replacement (`user_data` is gone; there's no other forced-replace mechanism). Plan carefully — `terraform apply` after a Packer build will replace the instance.
- No `aws_key_pair` resource. SSH is not used.
- Domain `fuhriman.org` is delegated from Squarespace to Route53 via NS records (manual one-time step in the registrar).
- Chart versions: ArgoCD 9.5.15; argocd-apps 1.6.2; cert-manager 1.14.0; envoy-gateway v1.3.0; external-dns 1.15.0.
- Workload images must be **multi-arch** (`linux/amd64,linux/arm64`) since the node is ARM. The `fuhriman-website` repo's CI builds both.

## Sibling repos

- **`argocd-app-of-apps`** — Helm chart declaring ArgoCD `Application` resources for the cluster workloads. Sync waves: cert-manager (-2) → envoy-gateway (-1) → external-dns (0) + fuhriman-website (0).
- **`eks-helm-charts`** — Chart sources consumed by App-of-Apps Applications. Includes `cert-manager`, `envoy-gateway` (also owns the shared Gateway, Certificate, and ArgoCD HTTPRoute templates), `external-dns`, `fuhriman-chart`. The name is vestigial — deploy target is k3s, not EKS.
- **`fuhriman-website`** — Next.js portfolio. CI publishes a multi-arch image to Docker Hub and auto-bumps the image tag in `eks-helm-charts/fuhriman-chart/values.yaml`.

## When working in this repo

**Defaults**:

- The **deployed state is the source of truth.** `terraform output`, `aws` CLI, `kubectl get`, and `git log` are authoritative. Plan docs under `docs/plans/` describe the journey and may not match current state.
- Run `terraform plan` before applying anything. A new AMI build forces instance replacement (and k3s CA regeneration — kubeconfig will need refresh after).
- New AWS resources get `local.tags` merged in; do not re-declare `Environment`/`ManagedBy`/`Project` per-resource — those come from `default_tags`.
- All cluster bootstrap belongs in the Packer AMI. New files for declarative bootstrap go in `packer/files/` (and `packer/files/k3s-manifests/` for things `helm-controller` should auto-apply). Avoid the temptation to introduce `user_data` again — there is one bootstrap mechanism, and it is the AMI.

**Gotchas**:

- DynamoDB lock table is gone. Don't add it back — `use_lockfile = true` is the supported pattern.
- The Gateway in `envoy-gateway-system` is **shared** by both the website and ArgoCD. Adding a new hostname means adding a SAN to `fuhriman-tls` (in the `envoy-gateway` chart) and a new HTTPRoute — not a new Gateway.
- ExternalDNS uses ambient EC2 instance-role credentials (no IRSA, no service-account annotations). The IAM policy is in the root `main.tf`; if you add another DNS-managing controller, attach to the same role.
- The OIDC trust policy in `oidc.tf` is scoped to the `furryman/terraform` repo. Forking won't transfer trust — replace the `sub` claim.
- Don't `terraform destroy` casually — the Route53 zone teardown is recoverable (Squarespace still has the NS records and can be repointed) but disruptive.
- First-boot debugging: without `user_data.sh` there is no `/var/log/k3s-init.log`. Use `journalctl -u k3s` for k3s server logs, `kubectl get helmchart,helmchartconfig -A` for the helm-controller view of in-flight chart installs, and `kubectl logs -n kube-system job/helm-install-argocd-<hash>` for the argo-cd install job's output.

## Reference

- `README.md` — operator-facing quick start and variable reference.
- `docs/plans/2026-05-22-modern-portfolio-architecture.md` — design doc (assumptions challenged, decisions, phased plan). Historical; not maintained.
- `docs/plans/2026-05-22-modern-portfolio-architecture-manual-steps.md` — operator checklist used during the refactor. Historical.
