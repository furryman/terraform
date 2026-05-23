# Modern Portfolio Architecture: End-State Plan

**Date:** 2026-05-22
**Status:** Design — pending stakeholder approval
**Author:** Architecture pass for adam@furryman.net
**Scope:** Complete refactor of fuhriman.org infrastructure across four repos (`terraform/`, `argocd-app-of-apps/`, `eks-helm-charts/`, `fuhriman-website/`), targeted at a Senior DevOps portfolio-grade end-state.

---

## Executive summary

The current stack works but carries debt that's visible to a portfolio reviewer:

1. **ArgoCD UI is exposed via NodePort 30443 with a self-signed cert.** Browser flags it as insecure — bad first impression.
2. **Admin access (SSH 22, kube-apiserver 6443) is `0.0.0.0/0`** and gated on a single shared variable.
3. **The hairpin-NAT iptables hack** in `user_data.sh` is brittle, undocumented in code, and a red flag in code review.
4. **`lifecycle.ignore_changes = [ami, user_data]`** silently drops bootstrap script updates after first apply.
5. **Terraform state is local** for an `environment = "prod"` stack.
6. **ArgoCD chart is 5.55.0** (Dec 2023) — four major versions stale; chart 9.x ships ArgoCD v3.x with significant security and feature improvements.
7. **`tf-modules/aws-vpc` carries a dead private subnet** with no route table.
8. **CLAUDE.md/README still describe `t3.micro`** in places (already partially fixed); two repos still claim it.

This document proposes the end-state architecture that resolves all of the above, plus a phased implementation that lets each phase ship independently. Cost stays under $25/mo (within current budget) and decreases by ~18% if the ARM compute migration is taken.

The end-state stack:

```text
Internet → Route53 (Terraform-managed)  → EC2 t4g.small (Graviton, k3s) → k3s services
              ↑                                ↑
              | (records created by            | (admin via SSM Session Manager — IAM-authenticated,
              |  ExternalDNS from Gateway      |  no public ports, full audit log)
              |  + HTTPRoute annotations)      |
              |                                 |
              | CoreDNS-custom ConfigMap inside cluster
              | rewrites fuhriman.org → envoy-gateway ClusterIP
              | (replaces the iptables hairpin fix)
              |
              | Let's Encrypt certs via cert-manager + HTTP-01 (gatewayHTTPRoute solver)
              | Both fuhriman.org and argocd.fuhriman.org get real browser-trusted certs

Routing: Envoy Gateway (Gateway API: GatewayClass + Gateway + HTTPRoute)
         No Ingress objects; ingress-nginx removed
Terraform state: S3 + native locking (use_lockfile)  → no DynamoDB (deprecated)
EBS backups: AWS DLM, monthly snapshots, keep 3 (~3 months of rollback history)
Budget: $25/mo alert (unchanged)
```

---

## Goals

1. **Eliminate the browser TLS warning** for ArgoCD — the originally-motivated problem.
2. **Eliminate the brittle iptables hairpin hack** at the runtime layer; replace with a declarative cluster-DNS solution.
3. **Eliminate `0.0.0.0/0` admin ingress** (SSH 22, kube-apiserver 6443) without trading it for a fragile home-IP allowlist.
4. **Operate on remote state** for production.
5. **Modernize Helm chart versions** (cert-manager, ingress-nginx, ArgoCD) to current.
6. **Demonstrate Senior DevOps practice** — declarative, version-pinned, IAM-audited, GitOps-managed.
7. **Lower or hold steady on cost.**

## Non-goals

- Migrating off k3s. Kubernetes is fixed for portfolio-signaling reasons.
- Multi-AZ / multi-region HA. A single-instance portfolio site doesn't need it; adding it would 3–5× the cost.
- Building a Packer pipeline. Worth doing eventually but not in scope here.
- Observability stack (Prometheus/Grafana). Mentioned as a future hook; intentionally out of scope.

---

## Current-state map (what's already in place)

Confirmed by file reads in this session:

| Layer | Component | State | Where |
|-------|-----------|-------|-------|
| AWS foundation | VPC, public subnet, IGW, route table | ✅ Working | `terraform/tf-modules/aws-vpc/` |
| AWS foundation | EC2 t3.small + IAM role w/ SSM-managed-instance-core | ✅ Working (SSM ready but unused) | `terraform/tf-modules/aws-k3s/` |
| AWS foundation | Local Terraform state | 🟡 Functional but risky | `terraform/backend.tf` (commented) |
| AWS foundation | $25/mo Budget alert | ✅ Working | `terraform/budget.tf` |
| Cluster bootstrap | k3s + Helm via cloud-init | ✅ Working | `terraform/tf-modules/aws-k3s/user_data.sh` |
| Cluster bootstrap | iptables hairpin NAT fix | 🟡 Working but brittle | `user_data.sh:92-113` |
| Cluster | ArgoCD installed via Helm + App-of-Apps | ✅ Working (chart 5.55.0 — stale) | `user_data.sh:51-90` |
| Cluster | ArgoCD UI exposure | 🔴 NodePort 30443, self-signed | `user_data.sh:55-56`, SG `main.tf:71-77` |
| GitOps | App-of-Apps chart in `argocd-app-of-apps/` | ✅ Working | three Application templates with sync waves |
| Cluster apps | cert-manager (chart 1.14.0) + `letsencrypt-prod` ClusterIssuer (HTTP-01) | ✅ Working | `eks-helm-charts/cert-manager/` |
| Cluster apps | ingress-nginx (chart 4.10.0, LoadBalancer service) | 🟡 Being replaced by Envoy Gateway in Phase 4 | `eks-helm-charts/ingress-nginx/` |
| Cluster apps | fuhriman-website (Next.js, Ingress with `letsencrypt-prod` annotation) | ✅ Working with valid LE cert | `eks-helm-charts/fuhriman-chart/` |
| Domain | fuhriman.org at Squarespace, manual A record to instance IP | 🟡 Manual on IP rotation | external |

**Key finding:** TLS via Let's Encrypt is *already working* for the main site. Cert-manager and ingress-nginx are in place. The ONLY thing missing for ArgoCD-on-trusted-TLS is an `Ingress` resource that points `argocd.fuhriman.org` at the `argocd-server` service. Everything else is plumbing the user already has.

---

## End-state architecture

### Layer 1 — Network & access

```
┌─────────────────────────────────────────────────────────────────────┐
│ VPC 10.0.0.0/16, us-west-2a (single AZ)                              │
│                                                                      │
│ Public subnet 10.0.1.0/24                                            │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │ EC2 t4g.small (ARM, AL2023-arm64)                            │   │
│   │  • EIP attached (stable IP across stop/start)                │   │
│   │  • IMDSv2 enforced                                           │   │
│   │  • IAM role: SSM Managed Instance Core + Route53 (cert/      │   │
│   │              ExternalDNS, scoped)                            │   │
│   │  • Security group:                                           │   │
│   │      INGRESS  80/tcp  ← 0.0.0.0/0 (HTTP, LE redirect)        │   │
│   │      INGRESS  443/tcp ← 0.0.0.0/0 (HTTPS)                    │   │
│   │      EGRESS   all     → 0.0.0.0/0                            │   │
│   │      (no 22, 6443, 30443 — gone entirely)                    │   │
│   └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                ▲                                  ▲
  External users│80/443                       Admin│SSM Session Manager
                │                                  │ (IAM-authenticated,
   Internet ────┘                                  │  AWS-StartPortForwardingSession
                                                   │  for kubectl)
                                                   │  No inbound port required
```

**Admin access uses only SSM Session Manager.** Three concrete operator workflows:

```bash
# Shell access
aws ssm start-session --target i-xxxxxxxxxxxx --region us-west-2

# kubectl access (port-forward 6443 to localhost)
aws ssm start-session \
  --target i-xxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}' \
  --region us-west-2
# Then: KUBECONFIG=./kubeconfig kubectl get nodes

# SCP-equivalent file copy (via S3 round-trip, or SCP-over-SSM with proxy)
```

All sessions are **IAM-authenticated and logged to CloudTrail** — the senior DevOps audit story.

### Layer 2 — DNS

| Record | Type | Value | Managed by |
|--------|------|-------|------------|
| `fuhriman.org` | A | EIP | ExternalDNS (from Ingress annotation) |
| `www.fuhriman.org` | A | EIP | ExternalDNS |
| `argocd.fuhriman.org` | A | EIP | ExternalDNS |

DNS migrates from Squarespace to **Route53** (1 public hosted zone, $0.50/mo). NS records updated once at the registrar (1–4hr propagation). After that, DNS is *declarative* — `Ingress` annotations in the cluster drive Route53 records via ExternalDNS. No more manual record entry on IP changes.

**Hairpin NAT solved at the cluster DNS layer**, not at iptables:

```yaml
# coredns-custom ConfigMap (kube-system)
fuhriman.org:53 {
    rewrite name fuhriman.org ingress-nginx-controller.ingress-nginx.svc.cluster.local
    forward . /etc/resolv.conf
}
argocd.fuhriman.org:53 {
    rewrite name argocd.fuhriman.org ingress-nginx-controller.ingress-nginx.svc.cluster.local
    forward . /etc/resolv.conf
}
```

Pods asking for `fuhriman.org` get the cluster-internal service IP. No iptables, no Route53 private zone, no `dnf install iptables-nft`. Persists across k3s restarts via `/var/lib/rancher/k3s/server/manifests/coredns-custom.yaml`.

### Layer 3 — Certificates

Keep the existing `letsencrypt-prod` ClusterIssuer with **HTTP-01** (already in `eks-helm-charts/cert-manager/templates/cluster-issuer.yaml`). No move to DNS-01 needed — that was the unnecessary complexity of the reverted aws-dns plan. The CoreDNS rewrite (Layer 2) means cert-manager's self-checks succeed cleanly.

Both `fuhriman.org` and `argocd.fuhriman.org` get real browser-trusted certificates via the same ClusterIssuer.

### Layer 4 — Traffic routing (Gateway API via Envoy Gateway)

ingress-nginx is replaced by **Envoy Gateway** as the Gateway API implementation. The cluster routes traffic via three resource types from `gateway.networking.k8s.io/v1`: `GatewayClass`, `Gateway`, and `HTTPRoute`. Cert-manager and ExternalDNS both consume Gateway API resources directly — no Ingress objects remain in the cluster.

```text
Internet :443 → SG → Envoy Gateway (LoadBalancer svc, klipper-lb maps to host net on k3s)
                            │
                            ▼
                       Gateway "public" (HTTPS listener, TLS via cert-manager)
                            │
                            ├─ HTTPRoute fuhriman.org      → svc/fuhriman-chart (Next.js)
                            ├─ HTTPRoute www.fuhriman.org  → svc/fuhriman-chart
                            └─ HTTPRoute argocd.fuhriman.org → svc/argocd-server :80
                                                              (TLS terminates at Gateway;
                                                               ArgoCD runs --insecure)
```

The new chart `eks-helm-charts/envoy-gateway/` carries the Envoy Gateway control plane (`oci://docker.io/envoyproxy/gateway-helm`) plus a single shared `Gateway` resource:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public
  namespace: envoy-gateway-system
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    external-dns.alpha.kubernetes.io/hostname: fuhriman.org,www.fuhriman.org,argocd.fuhriman.org
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: fuhriman-tls
      allowedRoutes:
        namespaces:
          from: All
```

Per-service `HTTPRoute` examples — these replace the current Ingress objects in `fuhriman-chart/` and add a new one for ArgoCD:

```yaml
# fuhriman-chart/templates/httproute.yaml — replaces ingress.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: fuhriman-website
  namespace: default
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
  hostnames:
    - fuhriman.org
    - www.fuhriman.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: fuhriman-chart
          port: 80
---
# argocd-app-of-apps/templates/argocd-httproute.yaml — new
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: public
      namespace: envoy-gateway-system
  hostnames:
    - argocd.fuhriman.org
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

The `letsencrypt-prod` ClusterIssuer's HTTP-01 solver switches from `ingress:` to `gatewayHTTPRoute:`:

```yaml
solvers:
  - http01:
      gatewayHTTPRoute:
        parentRefs:
          - name: public
            namespace: envoy-gateway-system
            kind: Gateway
```

ArgoCD's NodePort goes away. The Helm install loses `--set server.service.type=NodePort --set server.service.nodePortHttps=30443` and gains `--set 'configs.params.server\.insecure=true'` (so ArgoCD doesn't double-terminate TLS — Envoy Gateway terminates at the Gateway listener).

### Layer 5 — State backend

```hcl
terraform {
  backend "s3" {
    bucket       = "fuhriman-terraform-state"
    key          = "k3s/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true   # Native S3 locking — DynamoDB no longer needed
  }
}
```

The S3 bucket gets versioning, SSE-S3 encryption, and block-public-access. **No DynamoDB lock table** — that pattern is now deprecated in Terraform 1.15+. This is the modern best practice and one fewer AWS resource to manage.

### Layer 6 — Compute modernization (optional, recommended)

Switch EC2 instance type from `t3.small` (x86_64) to `t4g.small` (Graviton ARM):

- **Cost:** $17/mo → ~$12/mo (-30% on compute)
- **Catch:** Container images must be multi-arch. Next.js + Node on Linux/ARM is well-supported.
- **fuhriman-website CI** (in `fuhriman-website/.github/workflows/`) needs `docker buildx build --platform linux/amd64,linux/arm64` and a multi-arch image push.
- **k3s, ArgoCD, cert-manager, ingress-nginx** all ship ARM images — no work needed there.

This is the single biggest unforced cost optimization available. Strong portfolio signal (engineering judgment + cost discipline).

If multi-arch images are out of scope right now, keep `t3.small` — total cost stays at current ~$22.25/mo. Everything else in this plan is orthogonal.

---

## Decision log (assumptions challenged)

This section enumerates every meaningful architectural choice and the alternatives that were considered and rejected. Senior DevOps doesn't just pick — they show their work.

### Decision 1: Admin access via SSM, not by tightening 0.0.0.0/0 to an IP allowlist

**Chosen:** Remove ports 22 and 6443 from the security group entirely. Use SSM Session Manager.

**Alternative rejected — IP allowlist:** Home ISP WAN IPs are dynamic (hours to months between rotations). Pinning the SG to today's IP creates a self-lockout risk on ISP rotation. Also requires re-running Terraform on every rotation — operational toil.

**Alternative rejected — Tailscale / WireGuard mesh:** Operationally cleaner than IP pinning, but adds a third-party dependency that violates the "AWS-only" constraint.

**Alternative rejected — EC2 Instance Connect Endpoint:** EICE is designed for ad-hoc browser-style SSH to public instances. SSM Session Manager is the AWS-recommended pattern for IAM-controlled, audit-logged admin access to instances regardless of subnet topology. SSM also handles port-forwarding for kubectl, which EICE doesn't.

**Why SSM wins:** IAM-authenticated, full CloudTrail audit log, zero inbound ports, no IP pinning, no third-party dependency, IAM role is already attached. Costs $0.

### Decision 2: HTTP-01 cert challenges, not DNS-01

**Chosen:** Keep `letsencrypt-prod` ClusterIssuer with the HTTP-01 solver that's already in `eks-helm-charts/cert-manager/templates/cluster-issuer.yaml`.

**Alternative rejected — DNS-01 (the reverted aws-dns approach):** DNS-01 requires:
- A DNS provider with API (Route53 yes; Squarespace no)
- Either cert-manager pods using IAM ambient credentials (extra IAM policy + tight coupling to AWS) or a secret-based credential (more state to manage)
- More-fragile failure modes when zone records are slow to propagate

**Why HTTP-01 wins for this setup:** It's already working. It needs nothing from AWS. The only reason DNS-01 was attractive was *wildcard certs*, which a portfolio site doesn't need (every subdomain can have its own cert).

### Decision 3: CoreDNS rewrite, not iptables hairpin or Route53 split-horizon

**Chosen:** A `coredns-custom` ConfigMap with the `rewrite` plugin maps `fuhriman.org` and `argocd.fuhriman.org` to the in-cluster `ingress-nginx-controller` service IP. Persisted via `/var/lib/rancher/k3s/server/manifests/`.

**Alternative rejected — current iptables hack:**
- Brittle: depends on kube-proxy's KUBE-EXT-* chain names which can change across kube-proxy versions
- Non-declarative: lives in `user_data.sh`, ignored by Terraform after first apply (`lifecycle.ignore_changes`)
- Non-idempotent: uses `iptables -A` not `iptables -C ... || -A`; re-runs would duplicate
- Requires installing `iptables-nft` because AL2023 has no iptables OOTB

**Alternative rejected — Route53 split-horizon (the reverted aws-dns approach):**
- Two hosted zones to manage instead of one
- Private hosted zone requires VPC association, adds AWS resources
- DNS propagation downtime during Squarespace → Route53 NS cutover (1–4hr)
- Solves the wrong layer of the stack: DNS resolution in the cluster should be solved by cluster DNS (CoreDNS), not by a parallel external DNS system

**Why CoreDNS wins:**
- *Pure DNS* solution — no networking hacks
- Lives in the cluster, *declarative* via a ConfigMap committed to `eks-helm-charts/`
- Survives k3s restarts and upgrades via `/var/lib/rancher/k3s/server/manifests/`
- Reuses primitives that already exist; nothing new to install

### Decision 4: ExternalDNS + Route53, not Squarespace-with-manual-records

**Chosen:** Migrate DNS to Route53; use ExternalDNS in the cluster to manage records from `Ingress` annotations.

**Alternative rejected — keep Squarespace, add an A record for `argocd.fuhriman.org` manually:** Faster (no DNS migration), $0/mo cheaper. But:
- Every IP rotation requires manual DNS edits in Squarespace UI
- Adding new subdomains is a manual step
- Not declarative — no GitOps for DNS
- Weak portfolio signal: "I clicked around in Squarespace" vs. "I run declarative DNS via ExternalDNS"

**Alternative rejected — Squarespace + a cron job to update DNS:** Adds Squarespace API surface, which doesn't exist anyway.

**Why Route53 wins:** $0.50/mo for the hosted zone + free first-billion ExternalDNS-driven queries. Records flow from Ingress YAML via ExternalDNS, fully GitOps. Strong portfolio signal.

**Trade-off acknowledged:** 1–4hr propagation downtime during NS cutover at the Squarespace registrar. Mitigated by lowering TTL on existing records to 300s 24hrs before cutover.

### Decision 5: Native S3 state locking, not S3 + DynamoDB

**Chosen:** `use_lockfile = true` in the S3 backend block. No DynamoDB table.

**Alternative rejected — S3 + DynamoDB:** This is the older idiom. Terraform 1.15+ docs state DynamoDB-based locking is now *deprecated and will be removed in a future minor version*. Choosing the deprecated path for a 2026-built portfolio doesn't read well.

**Why native locking wins:** Modern, simpler, one fewer AWS resource, one fewer IAM permission to grant. Cost difference is negligible (DynamoDB on-demand was already near-zero); the win is in elegance.

### Decision 6: t4g.small (ARM Graviton), not t3.small (x86_64)

**Chosen:** Switch to Graviton if multi-arch image builds are feasible.

**Alternative — stay on t3.small:** Zero migration cost; keeps the current x86_64 toolchain. Costs ~$5/mo more.

**Why ARM wins (conditional):** ~30% compute cost reduction, native Linux/ARM workloads have been Tier-1 in the Node and Next.js ecosystems for years, strong portfolio signal for cost discipline + modern architecture awareness. Conditional on the `fuhriman-website` CI being able to build multi-arch images, which is a standard `docker buildx` setup.

**If skipped, plan is otherwise unchanged.** Pure orthogonal optimization.

### Decision 7: Gateway API via Envoy Gateway, not ingress-nginx + Ingress

**Chosen:** Migrate the routing layer to **Gateway API** (`gateway.networking.k8s.io/v1`) with **Envoy Gateway** as the implementation. Delete the existing ingress-nginx chart and all `Ingress` resources.

**Alternative rejected — stay on ingress-nginx + Ingress:** Mature, battle-tested, less work. But Gateway API is now the upstream-recommended traffic primitive (GA since Kubernetes 1.29 / Oct 2023; v1.2+ widely adopted in production). For a 2026 portfolio, choosing the *previous-generation* API to avoid a one-time migration sends the wrong signal.

**Alternative considered — NGINX Gateway Fabric (F5's pure Gateway API):** Plausible narrative ("migrated from ingress-nginx to NGINX Gateway Fabric, same data plane, modern control surface"). Rejected because it's newer, less battle-tested than Envoy Gateway, and the data-plane continuity isn't a benefit for a cluster that's being rebuilt anyway.

**Alternative considered — Traefik v3:** k3s ships Traefik by default; we explicitly disabled it via `--disable=traefik` and would have to re-enable. Gateway API support in Traefik v3 is solid. Rejected because:
- "I use the k3s default" is the *weakest* portfolio signal of all the options
- Re-enabling traefik means undoing the explicit choice that's already in `user_data.sh`

**Alternative considered — Cilium Gateway API:** Cilium would replace the entire CNI (k3s currently uses flannel). Too invasive for a single-instance portfolio cluster.

**Why Envoy Gateway wins:**
- Pure Gateway API implementation — the reference impl for Envoy, CNCF sandbox→incubating
- v1.0 released early 2024; v1.3+ stable as of mid-2026
- cert-manager has stable Gateway API support (`gatewayHTTPRoute` solver) since v1.15 (Aug 2024)
- ExternalDNS has stable Gateway API source since v0.14 (early 2024)
- Memory footprint comparable to ingress-nginx (~150–200 MB combined for control plane + data plane); fits comfortably on t3.small / t4g.small
- Strongest "I chose Gateway API on its own merits" portfolio signal

**Acknowledged trade-off (per user direction "ok if not fully featured"):** Some advanced ingress-nginx features have no Gateway API parity yet — rate limiting via the `RateLimitPolicy` extension is still alpha in Envoy Gateway; complex auth flows need extension policies. For a portfolio site at zero-to-low traffic, none of this matters. If a future feature needs it, ingress-nginx can be reintroduced in a single namespace.

### Decision 8: Pin AMI explicitly, drop `lifecycle.ignore_changes`

**Chosen:** Pin to a specific AMI ID (looked up at apply time but committed to the diff). Remove `lifecycle.ignore_changes = [ami, user_data]`.

**Alternative rejected — keep `ignore_changes`:** The reason it was added is reasonable (avoid surprise instance recreation when AWS publishes a new AL2023 AMI). But the same `ignore_changes` silently swallows updates to `user_data.sh` — the entire bootstrap script becomes unmanageable. The CoreDNS-custom rewrite and the SSM-only access pattern (this plan) both require user_data changes to land; if `ignore_changes` is in place they won't.

**Why pinning wins:** Explicit AMI bumps via PR. User_data changes propagate. No silent updates.

### Decision 9: ArgoCD chart bump from 5.55.0 to 9.5.x (current)

**Chosen:** Upgrade to chart 9.5.x (ArgoCD v3.x).

**Risks:**
- Chart 5 → 9 spans 4 major versions; ArgoCD itself jumps from v2.9 → v3.x
- v3.x has redesigned UI, deprecated CLI flags, RBAC schema changes
- Helm values schema has shifted (e.g., `server.service.type` paths, `configs.params` keys)

**Mitigation:**
- Upgrade in a staging k3s on the same EC2 first (one-shot test, `helm install` to a separate namespace)
- Read the migration notes in the argo-helm repo CHANGELOG for each major
- Take an EBS snapshot before the production helm upgrade

**Why bump anyway:** Two years of security patches and CVE fixes accrued. Chart 5.55.0 is at end-of-effective-life. Portfolio signal of "I run on supported versions" matters.

### Decision 10: Drop the dead private subnet in `aws-vpc`

**Chosen:** Delete `aws_subnet.private` from `tf-modules/aws-vpc/main.tf`. It has no route table and nothing consumes it.

**Alternative rejected — keep for "future use":** YAGNI. When a future use case arrives, it will want different sizing/AZ count. Add it then.

---

## Phased implementation plan

Each phase is independently shippable, with its own commit and validation step. The order is chosen so that each phase reduces risk before the next.

### Phase 0 — Pre-work (no infrastructure changes)

**Goal:** Set up remote state before touching anything else. Worst-case for a botched apply is recoverable.

| Task | Files | Validation |
|------|-------|------------|
| 0.1 Provision S3 bucket `fuhriman-terraform-state` via CLI (one-shot, not via Terraform) | (shell) | `aws s3 ls s3://fuhriman-terraform-state` |
| 0.2 Configure bucket: versioning, SSE-S3, block-public-access | (shell) | `aws s3api get-bucket-versioning ...` |
| 0.3 Uncomment & update `backend.tf` with `use_lockfile = true` (no DynamoDB block) | `backend.tf` | `terraform init -migrate-state` succeeds |
| 0.4 Verify lock works: open two `terraform plan` in parallel; one must fail with "lock acquired" | (shell) | observed |
| 0.5 Add a new `dlm.tf` (or extend `budget.tf`'s sibling section) declaring an `aws_dlm_lifecycle_policy` for the k3s root EBS volume: schedule `cron(0 4 1 * ? *)` (monthly, 04:00 UTC, 1st of the month), retention `count = 3`, target by tag `Cluster = fuhriman-k3s` | new `dlm.tf` | `terraform plan` shows policy + role |
| 0.6 Add the IAM role + policy DLM requires (`AWSDataLifecycleManagerServiceRole` is AWS-managed; attach to a new `aws_iam_role` with the DLM service principal) | `dlm.tf` | role created |
| 0.7 Verify after first run: `aws dlm get-lifecycle-policy ...` shows the schedule; first manual snapshot via `aws dlm create-snapshot ...` (or wait for the cron) | (shell) | snapshot appears in EC2 → Snapshots |

**Commit:** `feat: enable S3 backend with native lockfile; add DLM monthly EBS snapshots (keep 3)`

### Phase 1 — Variable cleanup + dead code (currently in flight)

**Goal:** Land the security-group variable refactor cleanly and remove dead code so subsequent phases have a clean base.

| Task | Files | Validation |
|------|-------|------------|
| 1.1 ✅ Rename `allowed_ssh_cidrs` → `allowed_admin_cidrs` (done) | several | `terraform validate` |
| 1.2 Delete `aws_subnet.private` from `tf-modules/aws-vpc/` | `tf-modules/aws-vpc/main.tf`, `outputs.tf` | `terraform plan` shows destroy of unused subnet |
| 1.3 Drop redundant `depends_on = [module.vpc]` in root `main.tf` | `main.tf` | `terraform plan` shows no diff |
| 1.4 Fix tag duplication: remove `Environment`, `ManagedBy` from `local.tags` (provider `default_tags` covers them) | `main.tf` | unchanged tag set on resources |
| 1.5 Drop module-level `instance_type` default to remove the t3.small/t3.micro mismatch | `tf-modules/aws-k3s/variables.tf` | `terraform validate` |
| 1.6 Add `validation` blocks for `budget_notification_email` (email format), `vpc_cidr` (valid CIDR), `instance_type` (allow-list) | `variables.tf`, `tf-modules/*/variables.tf` | `terraform plan` rejects invalid input |
| 1.7 Pin AWS provider to `~> 5.x.y` (current minor); pin Terraform `~> 1.15` | `providers.tf` | `terraform init` |
| 1.8 Pin AMI ID explicitly (look up `data.aws_ami.amazon_linux` once, commit the ID, drop `most_recent`) | `tf-modules/aws-k3s/main.tf` | unchanged apply |
| 1.9 Remove `lifecycle.ignore_changes = [ami, user_data]` | `tf-modules/aws-k3s/main.tf` | `terraform plan` shows expected updates flowing |
| 1.10 Fix misleading AZ slicing: replace `slice(azs.names, 0, 2)` (picks 2, uses 1) with `[data.aws_availability_zones.available.names[0]]` | `tf-modules/aws-vpc/main.tf` | reads honestly as single-AZ |
| 1.11 DRY the two duplicate `notification` blocks in `budget.tf` into a single `dynamic "notification"` block over `for_each = toset([80, 100])` | `budget.tf` | `terraform plan` shows no diff |
| 1.12 Delete unused outputs `public_subnet_ids` and `private_subnet_ids` (plural arrays — no consumers) from `tf-modules/aws-vpc/outputs.tf` | `tf-modules/aws-vpc/outputs.tf` | smaller module surface |
| 1.13 Enforce IMDSv2 via `metadata_options { http_tokens = "required", http_endpoint = "enabled", http_put_response_hop_limit = 2 }` on the EC2 instance | `tf-modules/aws-k3s/main.tf` | metadata service rejects unauthenticated requests |

**Commit cadence:** 3–4 small commits.

### Phase 2 — Admin access: SSM-only

**Goal:** Eliminate exposed admin ports and prove SSM works for shell + kubectl before tearing down the existing access path.

| Task | Files | Validation |
|------|-------|------------|
| 2.1 Verify SSM works: `aws ssm start-session --target $INSTANCE_ID` opens a shell | (shell) | observed |
| 2.2 Verify SSM port-forward: `aws ssm start-session ... --document-name AWS-StartPortForwardingSession ...` lets kubectl reach :6443 | (shell) | `kubectl get nodes` via tunnel |
| 2.3 Delete `ingress` blocks for ports 22 and 6443 from SG | `tf-modules/aws-k3s/main.tf` | `terraform plan` shows rule removal |
| 2.4 Drop the `aws_key_pair` resource and `key_name` from instance (SSM-only, no SSH key needed) | `tf-modules/aws-k3s/main.tf` | reduced surface |
| 2.5 Drop `ssh_public_key` and `allowed_admin_cidrs` variables (no consumers after 2.3/2.4) | `variables.tf`, `tf-modules/aws-k3s/variables.tf` | `terraform validate` |
| 2.6 Remove `ssh_public_key` from `terraform.tfvars` | `terraform.tfvars` | apply succeeds |
| 2.7 Update outputs: drop `ssh_command`; replace with `ssm_session_command` and `ssm_port_forward_kubectl_command` | `tf-modules/aws-k3s/outputs.tf`, root `outputs.tf` | helpful guidance |

**Commit:** `feat: SSM-only admin access; remove SSH and kube-apiserver public ingress`

**Rollback if needed:** revert the commit. The IAM SSM policy was already attached, so SSM is independent of these changes — nothing to undo there.

### Phase 3 — Route53 + ExternalDNS (DNS modernization)

**Goal:** Migrate DNS to Route53 and put ExternalDNS in the cluster to manage records declaratively.

| Task | Files | Validation |
|------|-------|------------|
| 3.1 Lower TTL on existing Squarespace A records to 300s (24hrs before cutover) | (Squarespace UI) | `dig fuhriman.org` shows new TTL |
| 3.2 Add a new `tf-modules/aws-dns/` (similar to the reverted module, but **public zone only — no private zone**) | new files | `terraform plan` |
| 3.3 Add Route53 records output (NS records) to root `outputs.tf` | `outputs.tf` | NS values printed |
| 3.4 Add Route53 IAM policy attached to instance role: `route53:ListHostedZones`, `route53:ChangeResourceRecordSets` (scoped to the zone) for ExternalDNS | `main.tf` | IAM diff in plan |
| 3.5 Apply Terraform | (shell) | zone created |
| 3.6 At Squarespace: replace nameservers with the Route53 NS records | (Squarespace UI) | manual step |
| 3.7 Wait for propagation (1–4hrs); verify `dig fuhriman.org @<route53-ns>` | (shell) | observed |
| 3.8 In `eks-helm-charts/`: add a new `external-dns/` chart (subchart wrapper on `oci://registry.k8s.io/external-dns/charts/external-dns`) with values pointing at the Route53 zone, IAM ambient credentials | new files | helm install via ArgoCD |
| 3.9 In `argocd-app-of-apps/templates/`: add `external-dns.yaml` Application with sync-wave `-1.5` (between cert-manager and ingress-nginx) | new file | ArgoCD picks it up |
| 3.10 Add `external-dns.alpha.kubernetes.io/hostname: fuhriman.org,www.fuhriman.org` annotation to `fuhriman-chart` Ingress | `fuhriman-chart/values.yaml` (and template if needed) | record auto-created |

**Commit cadence:** Terraform changes in one commit; chart changes in two commits in the other repos.

**Rollback if needed:** in the worst case (DNS cutover fails), point Squarespace back at the original nameservers and re-add the A records manually. EBS snapshot taken in 0.x covers any state weirdness.

### Phase 4 — Routing layer migration (ingress-nginx → Envoy Gateway) + CoreDNS rewrite

**Goal:** Replace ingress-nginx with Envoy Gateway, migrate every routing primitive to Gateway API (`Gateway` + `HTTPRoute`), switch cert-manager and ExternalDNS to consume Gateway API resources, then eliminate the iptables hairpin hack by pointing a `coredns-custom` ConfigMap at the new Envoy Gateway service. This is the largest phase — but the steps are cohesive (every change is part of the same routing-layer rebuild).

| Task | Files | Validation |
|------|-------|------------|
| 4.1 Add new `eks-helm-charts/envoy-gateway/` subchart wrapping `oci://docker.io/envoyproxy/gateway-helm` (pin to current stable, ~v1.3.x); set `service.type=LoadBalancer` so klipper-lb maps it to host net | new chart | helm install resolves |
| 4.2 Add `GatewayClass` (controller `gateway.envoyproxy.io/gatewayclass-controller`) and a single shared `Gateway` resource named `public` in namespace `envoy-gateway-system`, with HTTP :80 + HTTPS :443 listeners and `external-dns` + `cert-manager` annotations | `envoy-gateway/templates/` | Gateway gets a `Programmed=True` status |
| 4.3 Update `eks-helm-charts/cert-manager/templates/cluster-issuer.yaml`: HTTP-01 solver `ingress:` → `gatewayHTTPRoute:` with `parentRefs` to the `public` Gateway | `cluster-issuer.yaml` | renewals proceed via HTTPRoute challenges |
| 4.4 Enable cert-manager Gateway API support: add `featureGates: "ExperimentalGatewayAPISupport=true"` to `eks-helm-charts/cert-manager/values.yaml` (if not stable in chart version) | `values.yaml` | cert-manager logs show Gateway watcher active |
| 4.5 In `eks-helm-charts/fuhriman-chart/`: rename `templates/ingress.yaml` → `templates/httproute.yaml`, rewrite as `HTTPRoute` referencing the `public` Gateway; remove `cert-manager.io/cluster-issuer` annotation from values (now lives on the Gateway) | `fuhriman-chart/templates/`, `values.yaml` | site still loads with valid cert |
| 4.6 In `argocd-app-of-apps/templates/`: replace `ingress-nginx.yaml` Application with `envoy-gateway.yaml`; sync-wave stays at `-1` | new + delete | ArgoCD reconciles |
| 4.7 In `argocd-app-of-apps/values.yaml`: rename `apps.ingressNginx` → `apps.envoyGateway`; namespace `envoy-gateway-system` | `values.yaml` | values consistent with templates |
| 4.8 Verify ExternalDNS picks up Gateway hostnames: ExternalDNS chart (added in Phase 3) needs `sources: [gateway-httproute, gateway-grpcroute]` instead of (or in addition to) `[ingress]` | `external-dns/values.yaml` | Route53 records auto-created from Gateway annotations |
| 4.9 Add `eks-helm-charts/coredns-custom/` chart producing a `coredns-custom` ConfigMap in `kube-system` with `rewrite name` rules for `fuhriman.org`, `www.fuhriman.org`, and `argocd.fuhriman.org` → `envoy-gateway.envoy-gateway-system.svc.cluster.local` | new chart | `kubectl run --image=alpine -- nslookup fuhriman.org` resolves to cluster ClusterIP |
| 4.10 Force a cert-manager renewal to validate the self-check path works through CoreDNS rewrite (no iptables): `kubectl annotate certificate fuhriman-tls cert-manager.io/issue-temporary-certificate=true` | (shell) | challenge succeeds |
| 4.11 Once 4.10 passes, remove the entire hairpin NAT section from `user_data.sh` (lines 92–113) and the `dnf install -y iptables-nft` line | `tf-modules/aws-k3s/user_data.sh` | shorter, fully-declarative bootstrap |
| 4.12 Replace the `until ping -c1 google.com` infinite loop with a bounded `curl -sf https://get.k3s.io >/dev/null` check + max-attempts counter that fails the script after ~2 minutes | `tf-modules/aws-k3s/user_data.sh` | cloud-init no longer hangs forever on broken egress |
| 4.13 Taint the EC2 instance and re-apply Terraform to reprovision with the cleaner user_data (validates end-to-end) | (shell) | new instance comes up green, all routes work |

**Commit cadence:** Three commits across two repos:
- `eks-helm-charts/`: `feat: replace ingress-nginx with Envoy Gateway; migrate to Gateway API`
- `argocd-app-of-apps/`: `feat: swap ingress-nginx Application for envoy-gateway`
- `terraform/`: `feat: replace iptables hairpin NAT with coredns-custom rewrite; harden user_data bootstrap`

**Rollback if needed:** Re-add the ingress-nginx Application in app-of-apps and restore the Ingress in fuhriman-chart from git history; the iptables script is recoverable from `git show HEAD~N:tf-modules/aws-k3s/user_data.sh`. EBS snapshot taken in Phase 0 covers any deeper damage.

### Phase 5 — ArgoCD via HTTPRoute + chart upgrade

**Goal:** Put ArgoCD behind the same Gateway-terminated TLS as the website. Upgrade the chart from 5.55.0 to 9.5.x in the same window.

| Task | Files | Validation |
|------|-------|------------|
| 5.1 Pre-upgrade EBS snapshot (DLM monthly schedule from Phase 0 may not be in the right window — take an ad-hoc one) | (shell) | `aws ec2 create-snapshot ...` |
| 5.2 In `user_data.sh` + `variables.tf`: bump `argocd_chart_version` default from `5.55.0` to current `9.5.x` | `tf-modules/aws-k3s/user_data.sh`, `variables.tf` | new helm install picks it up |
| 5.3 Replace `--set server.service.type=NodePort --set server.service.nodePortHttps=30443` with `--set 'configs.params.server\.insecure=true'` in the helm install command (service type defaults to ClusterIP, which is what an HTTPRoute backend needs) | `user_data.sh` | ArgoCD listens on HTTP-only, TLS terminates at Gateway |
| 5.4 Add `argocd-httproute.yaml` to `argocd-app-of-apps/templates/` referencing the `public` Gateway (`parentRefs` to `envoy-gateway-system/public`), hostname `argocd.fuhriman.org`, backend `argocd-server:80` | new file | HTTPRoute created; `Accepted=True` status |
| 5.5 Verify cert-manager extends the Gateway's `fuhriman-tls` Secret to cover `argocd.fuhriman.org` (single multi-SAN cert) — or split into a separate Certificate if simpler | `cluster-issuer.yaml` or new `Certificate` | `kubectl get certificate -A` shows Ready=True |
| 5.6 Verify `https://argocd.fuhriman.org` loads with a green padlock | (browser) | observed |
| 5.7 Remove the ArgoCD NodePort 30443 ingress rule from SG (the only remaining non-80/443 inbound after Phase 2) | `tf-modules/aws-k3s/main.tf` | `terraform plan` shows the rule removal |
| 5.8 Update `argocd_url` output from `https://<ip>:30443` to `https://argocd.fuhriman.org` | `tf-modules/aws-k3s/outputs.tf` | accurate output |

**Commit cadence:** Two PRs — one in `terraform/` (chart bump + SG cleanup), one in `argocd-app-of-apps/` (HTTPRoute manifest).

**Rollback:** EBS snapshot from 5.1 is the safety net. The full process restores ArgoCD to chart 5.55.0 with the NodePort.

### Phase 6 — Compute migration to Graviton (optional)

**Goal:** Cut ~30% off compute cost by switching to ARM. Conditional on multi-arch image builds.

| Task | Files | Validation |
|------|-------|------------|
| 6.1 In `fuhriman-website/.github/workflows/`: switch the Docker build to `docker buildx --platform linux/amd64,linux/arm64`; push as multi-arch manifest | CI config | image runs on ARM |
| 6.2 In `fuhriman-chart/values.yaml`: no change (image tag stays the same; manifest covers both arches) | none | n/a |
| 6.3 In `terraform/tf-modules/aws-k3s/main.tf`: change AMI filter from `al2023-ami-*-x86_64` to `al2023-ami-*-arm64`, instance type to `t4g.small` | `tf-modules/aws-k3s/main.tf`, `variables.tf` | re-provisioned instance |
| 6.4 Re-apply (instance recreated) | (shell) | k3s starts on ARM |
| 6.5 Verify all pods come up healthy: cert-manager, ingress-nginx, ArgoCD, ExternalDNS, fuhriman-chart | (shell) | observed |

**Commit:** `feat: migrate compute to t4g.small (Graviton ARM) for cost reduction`

**Rollback:** Switch the two values back. Instance is recreated.

### Phase 7 — Immutable infrastructure: Packer-built AMI

**Goal:** Move the install-time bootstrap (k3s, helm, kubectl, dependency pre-pulls) from imperative `user_data.sh` into a versioned, Packer-baked AMI. Cold-start drops from ~5 min to ~30 sec; cluster bootstrap becomes a build artifact rather than a boot-time script. Strongest "immutable infrastructure" portfolio signal in the entire plan.

**Prerequisite:** Phases 0–6 complete and stable. Bake the *final* shape of the bootstrap; don't bake-then-redesign.

| Task | Files | Validation |
|------|-------|------------|
| 7.1 Add `packer/` directory at the repo root with `k3s-portfolio.pkr.hcl` (amazon-ebs builder, source AMI = `al2023-ami-*-arm64` after Phase 6, builder instance `t4g.small`) | new files | `packer validate` passes |
| 7.2 Add provisioner scripts (`packer/scripts/install-k3s.sh`, `install-helm.sh`, `prepull-images.sh`) that perform the install-time parts of the current `user_data.sh`: `k3s` install, `helm` install, `kubectl` binary, plus `crictl pull` of cert-manager / envoy-gateway / argo-cd / external-dns / coredns / Next.js images for faster first-boot | `packer/scripts/` | `packer build` succeeds; AMI tagged |
| 7.3 Add `.github/workflows/build-ami.yml` triggering `packer build` on push of a `packer-vX.Y.Z` tag; AMI tagged with `ManagedBy=Packer`, `Version=<git-sha>`, `Cluster=fuhriman-k3s` | new workflow | first build produces a tagged AMI |
| 7.4 Add AMI lifecycle: a CI cleanup step (in the same workflow) that lists AMIs by tag, sorts by `CreationDate` desc, and `aws ec2 deregister-image` + `aws ec2 delete-snapshot` everything beyond the most recent 3 | workflow | only 3 Packer AMIs retained |
| 7.5 In `tf-modules/aws-k3s/main.tf`: replace the `data "aws_ami" "amazon_linux"` block with a lookup filtered by tag `ManagedBy=Packer` + `Cluster=fuhriman-k3s`, `most_recent = true`, `owners = ["self"]` | `main.tf` | `terraform plan` resolves to the Packer AMI |
| 7.6 Strip `user_data.sh` down to *runtime-only* (~30–50 lines): fetch IMDSv2 token + public IP for `--tls-san`, start `k3s` server (already installed via AMI), `helm install argocd` (still runtime because the args depend on the instance), install App-of-Apps. Remove `dnf install`, `curl k3s.io | sh`, helm install, helm repo adds — all in the AMI now. | `tf-modules/aws-k3s/user_data.sh` | shorter, faster boot |
| 7.7 Taint the EC2 instance and re-apply to validate the new bootstrap path end-to-end | (shell) | cold-start drops to ~30 sec; all services come up |
| 7.8 Document the Packer workflow in `README.md`: how to build a new AMI, version tagging convention, expected build time | `README.md` | reproducible by reader |

**Commit cadence:** Three commits:
- `feat: add Packer config and CI workflow for k3s base AMI`
- `feat: AMI lifecycle cleanup (retain 3)`
- `feat: switch Terraform to consume Packer AMI; strip user_data to runtime-only`

**Rollback if needed:** Revert task 7.5 to point back at the upstream AL2023 AMI lookup. Old user_data still works (just slower at boot). Packer AMIs can be deregistered without affecting any running instance.

**Cost impact:** ~$0.10–0.50/mo for AMI snapshot storage (dedup-aware against existing DLM snapshots; the AMI's unique blocks are mostly the ~1 GB of baked-in binaries).

---

### Phase 8 — Documentation cleanup

**Goal:** Update CLAUDE.md and README files across all four repos to reflect the new architecture. Remove stale plan docs.

| Task | Files | Validation |
|------|-------|------------|
| 8.1 Update `terraform/CLAUDE.md` with the new architecture diagram, admin-via-SSM workflows, Gateway API, modern DNS/cert story, Packer build pipeline | `CLAUDE.md` | accurate |
| 8.2 Update `terraform/README.md` similarly + new ASCII architecture diagram | `README.md` | accurate |
| 8.3 Delete stale `docs/plans/2026-02-16-*.md` (reverted aws-dns design) | (rm) | clean repo |
| 8.4 In `eks-helm-charts/README.md`: fix the stale `t3.micro`/"free tier" references; mention Gateway API + Envoy Gateway, cert-manager, ExternalDNS, coredns-custom | `eks-helm-charts/README.md` | accurate |
| 8.5 In `argocd-app-of-apps/README.md`: update the architecture diagram (3 apps → 4-5 with envoy-gateway + external-dns + coredns-custom); refresh the sync-wave description | `argocd-app-of-apps/README.md` | accurate |
| 8.6 In `fuhriman-website/README.md` and `AGENT.md`: note the multi-arch image build requirement from Phase 6 (one-time CI update) | external files | accurate |

**Commit:** `docs: rewrite for SSM/Route53/ExternalDNS/Gateway API/Packer modern architecture`

---

## Cost analysis

### Current state ($/month)

| Component | Cost |
|-----------|------|
| EC2 t3.small (on-demand) | $17.00 |
| EBS 20 GB gp3 | $1.60 |
| Public IPv4 | $3.65 |
| DNS (Squarespace, included in domain) | $0.00 |
| Terraform state (local) | $0.00 |
| Budget alerts | $0.00 |
| **Total** | **$22.25** |

### End state, all phases including ARM migration ($/month)

| Component | Cost | Δ vs current |
|-----------|------|--------------|
| EC2 t4g.small (Graviton ARM, on-demand) | $12.10 | -$4.90 |
| EBS 20 GB gp3 | $1.60 | — |
| EIP (free while attached) | $0.00 | — |
| Public IPv4 (on the EIP) | $3.65 | — |
| Route53 hosted zone | $0.50 | +$0.50 |
| Route53 queries (well below first-billion free tier) | $0.00 | — |
| S3 state backend (storage + requests) | <$0.01 | +<$0.01 |
| DLM monthly EBS snapshots × 3 (no per-resource fee; ~22 GB-month stored) | ~$1.10 | +$1.10 |
| Packer AMI snapshot storage (1 retained, dedup'd against DLM) | ~$0.30 | +$0.30 |
| **Total** | **~$19.25** | **-$3.00/mo (-13.5%)** |

### End state, no ARM migration (compute unchanged)

Same as above but EC2 stays at $17.00 → total **~$24.15/mo** (+$1.90/mo from baseline, all from Route53 + DLM snapshots + state backend + Packer AMI).

### Cost floor (out-of-scope alternative)

If K8s weren't a constraint, hosting the static Next.js build on S3 + CloudFront + ACM cert would run about **$2–5/mo** for low-traffic portfolio scale. This is mentioned only to make the cost trade-off visible — keeping K8s costs you roughly $15/mo for the engineering-signaling value, which is reasonable for portfolio purposes.

### Why we can't easily reduce the $3.65 Public IPv4

The website needs to be reachable from the public internet, which requires at least one public IPv4 *somewhere*. The realistic alternatives all cost more:

- ALB in front of the EC2: +$17/mo
- NLB in front: +$16/mo
- CloudFront in front: routes to origin over IPv4 too, doesn't eliminate the charge
- IPv6-only EC2: works for IPv6-capable clients but the internet is still ~70% IPv4, so user-visible breakage

The $3.65/mo is essentially the floor for "I want a public website on AWS with a stable IP."

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| DNS migration causes downtime | Medium | Medium (1–4hr unreachable) | Lower TTL 24hr before cutover; cut over during low-traffic window; monitor `dig` from multiple resolvers |
| ArgoCD chart 5→9 upgrade breaks | Medium | High (cluster GitOps lost) | EBS snapshot before; helm rollback path; test on a fresh `helm install` in a separate namespace first |
| SSM port-forward for kubectl flakes | Low | Low (fallback: rev the SG temporarily) | Phase 2 explicitly validates SSM works BEFORE removing SSH; rollback is one revert |
| CoreDNS rewrite doesn't fix self-check | Low | Medium (certs don't renew) | Test in Phase 4 by forcing a renewal before removing iptables rules; keep iptables script available in git history |
| t4g ARM migration breaks fuhriman-website | Medium | Medium (site down) | Phase 6 is optional/last; the multi-arch image build is testable independently before the instance switch |
| Local→S3 state migration corruption | Very low | High (state lost) | `terraform init -migrate-state` is well-tested; back up the local state file before migration; S3 versioning catches incidents within minutes |
| Envoy Gateway data plane fails to come up after install (resource limits, CRD conflicts) | Medium | High (no traffic at all) | Validate in Phase 4 step-by-step: install controller → verify GatewayClass `Accepted=True` → install Gateway → verify `Programmed=True` *before* moving HTTPRoutes; rollback path is the ingress-nginx Application in git history |
| cert-manager `gatewayHTTPRoute` solver doesn't issue cert (Gateway API support gap) | Medium | Medium (broken TLS for a few hours) | Verify cert-manager chart version supports stable Gateway API (`v1.15+`); if not, temporarily revert to the Ingress solver until upgraded; manual cert via `cmctl renew` as fallback |
| ExternalDNS Gateway API source doesn't create records (annotation differences) | Low | Medium | Create the records manually via Terraform first; once ExternalDNS proves itself, remove the Terraform records and let it own them; ExternalDNS `--policy=upsert-only` prevents accidental deletes during verification |
| Packer AMI rebuild workflow adds friction (every bootstrap change → rebuild → re-apply) | Medium | Low (process pain, not outage) | Keep `user_data.sh` capable of falling back to install-from-scratch (don't *require* the baked AMI); CI workflow for AMI builds runs on tag, not on every commit, so casual edits don't trigger rebuilds |
| Packer build itself fails (broken provisioner script) | Medium | Low (no impact on running cluster) | Build runs in CI before promoting AMI tag; failed builds never produce a deployable AMI; existing running instance is unaffected |

---

## Decisions log

All open questions are now decided. Frozen by stakeholder approval:

| # | Question | Decision |
|---|----------|----------|
| 1 | ARM (Graviton) migration? | 🟢 **Yes** — Phase 6 in scope. ~$5/mo savings via t4g.small; multi-arch Docker builds added to `fuhriman-website` CI. |
| 2 | DNS at Squarespace, hybrid (NS delegation), or full Route53 migration? | 🟢 **Full Route53 migration** — Phase 3 unchanged. Squarespace acts as registrar only; all DNS records live in a single Route53 hosted zone. |
| 3 | ArgoCD chart bump 5.55.0 → 9.5.x? | 🟢 **Yes** — Phase 5.2. Risk mitigated by EBS snapshot before (5.1) + helm rollback path. |
| 4 | Routing layer: Ingress (ingress-nginx) or Gateway API (Envoy Gateway)? | 🟢 **Gateway API via Envoy Gateway** — Decision 7 and Phase 4. ingress-nginx removed entirely. |
| 5 | Backup policy? | 🟢 **DLM, monthly × 3** — Phase 0.5–0.7. ~3 months of rollback history, ~$1.10/mo. |
| 6 | Add a `monitoring/` chart (Prometheus + Grafana lite)? | 🟢 **No** — deferred to Future Hooks. Preserves ~1.3 GB workload headroom on t4g.small. |
| 7 | Implementation order? | 🟢 **As planned**: Phase 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Dependencies: Phase 3 (DNS) before Phase 4 (routing); Phase 4 before Phase 5 (ArgoCD HTTPRoute needs Gateway); Phase 6 (ARM) before Phase 7 (Packer) so AMI baking targets ARM from the start. |
| 8 | Packer-built AMI for immutable bootstrap? | 🟢 **Yes** — Phase 7. ~$0.30/mo AMI snapshot storage; cold-start drops ~5 min → ~30 sec. |

**Final committed monthly cost:** **~$19.25/mo** (all phases including ARM + Packer; under the $25/mo budget alert).

The plan is now ready for execution. Next operational step: start Phase 0 (remote state + DLM snapshot policy).

---

## Future hooks (out of scope but acknowledged)

These are deliberately deferred to avoid scope creep. Strong portfolio signal if added in a Phase 8+:

- **External Secrets Operator + AWS Secrets Manager/SSM Parameter Store** — for when there are actual secrets to manage
- **kube-prometheus-stack-lite** for observability (lightweight enough for t4g.small)
- **Renovate** at the chart layer to auto-PR Helm chart bumps
- **`tfsec` / `checkov` / `tflint` in CI** for IaC security baseline

---

## Review-finding coverage matrix

Every issue surfaced in the earlier code review of this codebase maps to a concrete task in this plan. This table is the contract — if a finding isn't here, the plan is incomplete.

| Severity | Finding | Where covered |
|----------|---------|---------------|
| 🔴 | CLAUDE.md drift (described reverted `aws-dns` module) | **Done** — commit `93c49d1`, before this plan |
| 🔴 | SSH (22) + k8s API (6443) open to `0.0.0.0/0` | Phase 2.3–2.7 (remove ingress entirely; SSM replaces) |
| 🔴 | ArgoCD NodePort (30443) open to `0.0.0.0/0` | Phase 5.7 (NodePort removed; Ingress on 443 takes over) |
| 🔴 | ArgoCD browser TLS warning (self-signed cert) — originally-motivated UX problem | Phase 5.4–5.6 (Ingress + cert-manager + Let's Encrypt) |
| 🔴 | Local Terraform state for prod | Phase 0 (S3 backend with native `use_lockfile`) |
| 🟡 | `lifecycle.ignore_changes = [ami, user_data]` silent-update trap | Phase 1.8 (pin AMI explicitly) + Phase 1.9 (remove ignore_changes) |
| 🟡 | ArgoCD chart 5.55.0 is ~2 years stale | Phase 5.2 (bump to 9.5.x) |
| 🟡 | `argocd-apps` chart `1.6.2` is also stale | Phase 5.2 (same commit) |
| 🟡 | Instance-type default mismatch (root `t3.small` vs module `t3.micro`) | Phase 1.5 (drop module-level default) |
| 🟡 | `user_data.sh` `until ping` bootstrap loop with no timeout | Phase 4.6 (bounded retry; check the real service URL not ICMP) |
| 🟡 | No variable validation blocks (email shape, CIDR validity, instance type allow-list) | Phase 1.6 |
| 🟡 | IMDSv2 not enforced at the instance level (only used opportunistically in user_data) | Phase 1.13 (`metadata_options.http_tokens = "required"`) |
| 🟢 | Tag duplication between provider `default_tags` and `local.tags` | Phase 1.4 |
| 🟢 | Private subnet in `aws-vpc` is dead infra (no route table, no consumer) | Phase 1.2 (delete) |
| 🟢 | Misleading `slice(azs, 0, 2)` (picks 2, uses 1) | Phase 1.10 |
| 🟢 | Redundant `depends_on = [module.vpc]` on the k3s module | Phase 1.3 |
| 🟢 | iptables rules in `user_data.sh` use `-A` (not idempotent) | Phase 4.4 (entire iptables section removed) |
| 🟢 | `budget.tf` repeats two near-identical `notification` blocks | Phase 1.11 (DRY with `dynamic` block) |
| 🟢 | `argocd_url` output uses IP, not DNS | Phase 5.8 (`https://argocd.fuhriman.org`) |
| 🟢 | Unused plural module outputs (`public_subnet_ids`, `private_subnet_ids`) | Phase 1.12 (delete) |
| 🟢 | EBS volume encryption uses default AWS-managed KMS key | Acknowledged; deferred to "Future hooks" — customer-managed KMS is portfolio polish, no security delta at this scale |
| 🟢 | Stale plan docs `docs/plans/2026-02-16-*.md` describing the reverted aws-dns work | Phase 7.3 (delete) |
| 🟢 | `eks-helm-charts/README.md` still describes `t3.micro` and "free tier eligible" | Phase 7.4 |
| ❓ | "Was aws-dns reverted because of a circular dep / cost / risk?" — original open question | Answered in conversation: reverted because the TLS warning was the only actual problem; the rest of the aws-dns design was scope creep. This plan solves the TLS warning via the simpler HTTP-01 + CoreDNS-rewrite path instead. |
| ❓ | "Are docs/plans/* active backlog or shelved?" | Answered: shelved. Phase 7.3 removes them. |
| ❓ | "Is t3.small actually enough?" | Confirmed in chart values: `fuhriman-chart` requests 50m CPU / 64Mi memory, limits 100m / 128Mi. Sufficient headroom on 2GB t3.small or t4g.small. |

## References

- [AWS Public IPv4 address charge announcement](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/) — $0.005/hr, effective Feb 1, 2024
- [Terraform S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3) — native `use_lockfile`, DynamoDB locking deprecated
- [Argo CD Helm chart releases](https://github.com/argoproj/argo-helm/releases) — current 9.5.x
- [k3s Advanced Options & CoreDNS customization](https://docs.k3s.io/advanced) — `/var/lib/rancher/k3s/server/manifests/`
- [CoreDNS custom DNS entries / rewrite plugin](https://coredns.io/2017/05/08/custom-dns-entries-for-kubernetes/)
- [AWS SSM Session Manager vs EC2 Instance Connect Endpoint](https://dev.to/jajera/secure-remote-access-to-ec2-instances-aws-ssm-session-manager-vs-ec2-instance-connect-vs-ec2-3j2p) — SSM recommended for IAM-controlled / audited admin access
- [Kubernetes Gateway API spec](https://gateway-api.sigs.k8s.io/) — GA since 1.29 (Oct 2023); current v1.2+
- [Envoy Gateway documentation](https://gateway.envoyproxy.io/) — Gateway API reference implementation for Envoy; v1.0 released Jan 2024
- [cert-manager Gateway API integration](https://cert-manager.io/docs/usage/gateway/) — `gatewayHTTPRoute` HTTP-01 solver; stable since v1.15
- [ExternalDNS Gateway API source](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/sources/gateway-api.md) — `gateway-httproute` source, GA
- [AWS Data Lifecycle Manager](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/snapshot-lifecycle.html) — EBS snapshot automation; no per-resource fee, storage cost only
