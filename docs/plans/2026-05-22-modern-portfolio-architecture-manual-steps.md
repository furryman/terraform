# Manual Steps — Modern Portfolio Architecture Execution

**Companion to:** [`2026-05-22-modern-portfolio-architecture.md`](./2026-05-22-modern-portfolio-architecture.md)
**Purpose:** Everything you (the operator) need to do by hand during execution, separated from the work an agent or `terraform apply` will do for you.

This is your checklist. Print it, scribble on it, paste it into a tracking issue — whatever helps. Each item is small enough to actually finish.

---

## ✅ Section 1 — One-time prerequisites (do once, before Phase 0)

### Tools to install on your local machine

- [ ] **AWS CLI v2** — `aws --version` should report `aws-cli/2.x.x` or newer.
  Install: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
- [ ] **Session Manager Plugin for AWS CLI** — required for `aws ssm start-session`.
  Install: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>
  Verify: `session-manager-plugin --version`
- [ ] **Terraform 1.15+** — `terraform -version` should report `1.15.x` or newer (needed for `use_lockfile`).
  Install: <https://developer.hashicorp.com/terraform/install>
- [ ] **kubectl** — for cluster admin via SSM port-forward.
  Install: <https://kubernetes.io/docs/tasks/tools/#kubectl>
- [ ] **helm** *(optional but useful)* — for ad-hoc cluster inspection.
  Install: <https://helm.sh/docs/intro/install/>
- [ ] **Packer 1.10+** *(only needed for Phase 7)* — defer until Phase 7.
  Install: <https://developer.hashicorp.com/packer/install>
- [ ] **dig** *(macOS: comes with system; Linux: `dnsutils` package)* — for DNS verification in Phase 3.

### AWS credentials

- [ ] `aws configure` completed with credentials that have sufficient permissions on the target account.
  Recommend creating a dedicated IAM user `terraform-portfolio` with the AWS-managed policies `AdministratorAccess` (during build-out) or scoped down later.
- [ ] `aws sts get-caller-identity` returns the expected account ID and user.
- [ ] Default region is `us-west-2` (or you remember to pass `--region us-west-2` to every command).

### Access checklist

- [ ] **Squarespace account access** — you need to log into <https://account.squarespace.com> to manage the registrar settings for `fuhriman.org`. Required in Phase 3.
- [ ] **GitHub access** to all four repos (push permissions):
  - `furryman/terraform` (this repo)
  - `furryman/argocd-app-of-apps`
  - `furryman/eks-helm-charts`
  - `furryman/fuhriman-website`
- [ ] **GitHub Actions secrets** in `furryman/fuhriman-website` (for multi-arch image builds in Phase 6) and `furryman/terraform` (for Packer AMI builds in Phase 7):
  - `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for a dedicated CI IAM user (or use OIDC role assumption — modern preference, set up in Phase 7).
- [ ] **A browser you trust** — for visiting `https://fuhriman.org` and `https://argocd.fuhriman.org` during verification steps.

---

## ✅ Section 2 — Per-phase manual steps

### Phase 0 — Remote state + DLM snapshots

**Manual steps:**

- [ ] **0a.** Run the S3 + bucket-policy setup commands from `README.md` (the "Backend Setup" section):

  ```bash
  aws s3api create-bucket \
    --bucket fuhriman-terraform-state \
    --region us-west-2 \
    --create-bucket-configuration LocationConstraint=us-west-2

  aws s3api put-bucket-versioning \
    --bucket fuhriman-terraform-state \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket fuhriman-terraform-state \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  aws s3api put-public-access-block \
    --bucket fuhriman-terraform-state \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  ```

  > ⚠️ **Note:** `--create-bucket-configuration LocationConstraint=us-west-2` is required because we're not in `us-east-1`. Omitting it produces a confusing `IllegalLocationConstraintException`.

- [ ] **0b.** Run `terraform init -migrate-state` (after the `backend.tf` block is uncommented in code) and answer "yes" when prompted to copy local state to S3.

  > ⚠️ **Before this step:** make a backup copy of `terraform.tfstate` locally. S3 versioning is safety-net #2; your local copy is safety-net #1.

- [ ] **0c.** Verify the S3 state file exists: `aws s3 ls s3://fuhriman-terraform-state/k3s/`

- [ ] **0d.** Verify locking works: open two terminals, run `terraform plan` in each within ~2 seconds. The second should fail with a lock-acquired error. Then unlock by letting the first finish.

- [ ] **0e.** After Terraform creates the DLM policy, verify the first scheduled snapshot fires on the 1st of the following month: check the EC2 console → Snapshots, filter by tag `Cluster=fuhriman-k3s`. Or trigger an ad-hoc run via `aws dlm get-lifecycle-policy ...`.

### Phase 1 — Variable cleanup

**Manual steps:** None. All changes are code; `terraform apply` after each commit picks them up.

> ⚠️ **Watch for:** Task 1.9 (removing `lifecycle.ignore_changes`) will cause Terraform to *want to replace* the EC2 instance on the next apply because the AMI lookup logic changed. Before running `apply`: review `terraform plan` carefully and decide whether to taint-and-replace now or hold until a maintenance window.

### Phase 2 — SSM-only admin access

**Manual steps:**

- [ ] **2a.** Verify SSM works *before* removing SSH ingress (this is task 2.1 in the plan, but it's also the most important manual gate):

  ```bash
  # Get instance ID
  INSTANCE_ID=$(terraform -chdir=. output -raw instance_id)

  # Try a shell session
  aws ssm start-session --target $INSTANCE_ID --region us-west-2

  # Exit the shell; should land back at your prompt
  exit
  ```

  > 🛑 **If `aws ssm start-session` fails:** do NOT proceed with removing SSH. Common causes:
  > - SSM plugin not installed locally (see prerequisites)
  > - Instance hasn't checked in to SSM yet (check `aws ssm describe-instance-information` — instance should appear in the list)
  > - IAM role missing `AmazonSSMManagedInstanceCore` (already attached, verify with `aws iam list-attached-role-policies --role-name fuhriman-k3s-k3s-role`)

- [ ] **2b.** Test kubectl port-forward via SSM (this is the more critical workflow):

  ```bash
  aws ssm start-session \
    --target $INSTANCE_ID \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}' \
    --region us-west-2
  # Leave this running in one terminal.
  ```

  In another terminal:

  ```bash
  # Copy kubeconfig (one-time)
  aws ssm start-session --target $INSTANCE_ID --region us-west-2
  # In the SSM shell:
  sudo cat /etc/rancher/k3s/k3s.yaml
  # Copy the YAML to your local ~/.kube/portfolio-config

  # Replace 127.0.0.1:6443 with localhost:6443 in the copied file (TLS-SAN should match).
  # Then test:
  KUBECONFIG=~/.kube/portfolio-config kubectl get nodes
  ```

  > Expected: `kubectl get nodes` returns the single node in `Ready` state.
  > If TLS error about hostname mismatch: the k3s `--tls-san` flag in `user_data.sh` needs to include `localhost` or `127.0.0.1` (it should already, but verify).

- [ ] **2c.** Only after 2a and 2b succeed: let `terraform apply` proceed to remove ports 22 + 6443 from the SG.

### Phase 3 — Route53 + ExternalDNS

**Manual steps:**

- [ ] **3a.** 24 hours before the NS cutover: at Squarespace, lower the TTL of every existing DNS record (`fuhriman.org`, `www.fuhriman.org`, any MX/TXT) to **300 seconds**. This shrinks the post-cutover propagation window from up to 24 hours down to ~5 minutes.

  Squarespace navigation: `Settings` → `Domains` → `fuhriman.org` → `DNS Settings` → edit each record.

- [ ] **3b.** After Terraform creates the Route53 zone, capture the 4 nameservers:

  ```bash
  terraform output nameservers
  # Outputs something like:
  # [
  #   "ns-1234.awsdns-12.org.",
  #   "ns-5678.awsdns-78.com.",
  #   "ns-9012.awsdns-90.net.",
  #   "ns-3456.awsdns-34.co.uk."
  # ]
  ```

- [ ] **3c.** At Squarespace: replace the registrar nameservers with the 4 Route53 NS values above.

  Squarespace navigation: `Settings` → `Domains` → `fuhriman.org` → `DNS Settings` → toggle "Use custom nameservers" → enter the 4 NS values → save.

  > 🛑 **This is the irreversible window.** Squarespace's automatic DNS records (apex A, www CNAME, MX) stop being served the moment custom NSes take over. The Route53 zone must already contain equivalents — confirm with `aws route53 list-resource-record-sets --hosted-zone-id <id>` before flipping at Squarespace.
  >
  > ⏱️ Expect **1–4 hours of partial unreachability** while DNS propagates. (Schedule this for a low-traffic window.)

- [ ] **3d.** Verify propagation from your machine and from a known-different network (use a phone on cellular, or `dig @8.8.8.8`):

  ```bash
  dig fuhriman.org @8.8.8.8 +short
  # Should return your EIP within a few minutes

  dig fuhriman.org @1.1.1.1 +short
  # Same

  dig argocd.fuhriman.org @8.8.8.8 +short
  # Should also return EIP (after ExternalDNS creates the record from the Gateway annotation)
  ```

- [ ] **3e.** Once `dig` from external resolvers returns the right IP, browse `https://fuhriman.org` to confirm the site loads. (Cert should still be valid from the previous HTTP-01 setup.)

### Phase 4 — Routing migration to Envoy Gateway + CoreDNS rewrite

**Manual steps:**

- [ ] **4a.** Confirm in ArgoCD UI (still on `https://<ip>:30443` at this point) that the new `envoy-gateway` Application syncs cleanly. If sync-wave ordering is off, the Gateway may not come up before the HTTPRoute tries to attach.

- [ ] **4b.** Smoke test the new routing:

  ```bash
  # From inside the cluster (via SSM + kubectl exec)
  kubectl run -it --rm test --image=alpine -- sh
  # Inside the pod:
  apk add curl
  curl -v http://fuhriman.org
  # Should resolve to a cluster ClusterIP and return HTML
  ```

- [ ] **4c.** Force a cert renewal to verify cert-manager's `gatewayHTTPRoute` solver works:

  ```bash
  kubectl annotate certificate fuhriman-tls cert-manager.io/issue-temporary-certificate=true -n default
  kubectl get challenges -A --watch
  # Wait for Status=Valid; expect ~30-60 seconds
  ```

- [ ] **4d.** After 4c succeeds, let Terraform reprovision the instance (Task 4.13). The reprovision will pick up the cleaner `user_data.sh` without the iptables hack.

  > ⚠️ Reprovisioning destroys/recreates the EC2. The EIP stays attached. The EBS root volume is recreated — but you have DLM snapshots from Phase 0. ArgoCD will reinstall from user_data, and apps will sync down from app-of-apps. **Expected total downtime: ~5–8 minutes.**

### Phase 5 — ArgoCD chart bump + HTTPRoute

**Manual steps:**

- [ ] **5a.** Take an ad-hoc EBS snapshot before the chart bump:

  ```bash
  VOLUME_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)
  aws ec2 create-snapshot \
    --volume-id $VOLUME_ID \
    --description "Pre-ArgoCD-chart-bump (5.55→9.5)" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Cluster,Value=fuhriman-k3s},{Key=ManagedBy,Value=ad-hoc}]'
  ```

  > Wait for the snapshot to reach `completed` state (a few minutes) before proceeding.

- [ ] **5b.** After Terraform applies + new ArgoCD chart installs, verify in browser: `https://argocd.fuhriman.org` should load with a green padlock (Let's Encrypt cert, not self-signed).

- [ ] **5c.** Verify ArgoCD UI functionality: log in (admin password unchanged), check that the App-of-Apps and all child Applications still show `Synced` and `Healthy`. If any are `OutOfSync` after the chart bump, this is where you intervene — most likely a values-schema change between chart 5.x and 9.x.

  > 🛑 **If anything goes sideways:** `helm rollback argocd 1 -n argocd` reverts to the previous chart version. If state is genuinely corrupted, restore from the 5a snapshot.

### Phase 6 — ARM (Graviton) migration

**Manual steps:**

- [ ] **6a.** In the `furryman/fuhriman-website` repo: edit `.github/workflows/*.yml` (the image build workflow) to enable multi-arch builds:

  ```yaml
  - name: Set up QEMU
    uses: docker/setup-qemu-action@v3

  - name: Set up Docker Buildx
    uses: docker/setup-buildx-action@v3

  - name: Build and push
    uses: docker/build-push-action@v5
    with:
      platforms: linux/amd64,linux/arm64   # <-- the key addition
      push: true
      tags: ${{ env.IMAGE_TAG }}
  ```

- [ ] **6b.** Push a tag to trigger a build. Verify multi-arch with:

  ```bash
  docker manifest inspect furryman/fuhriman-website:<tag>
  # Should list both linux/amd64 and linux/arm64
  ```

- [ ] **6c.** After Terraform changes (Phase 6 tasks 6.3–6.4), let it reprovision the instance on `t4g.small`. Expected downtime: 5–8 minutes (same as Phase 4 reprovision).

- [ ] **6d.** Verify all pods come up healthy on ARM: `kubectl get pods -A` — all `Running` or `Completed`. Pay attention to cert-manager, envoy-gateway, argocd, external-dns, fuhriman-chart. If any pod is `CrashLoopBackOff` with an `exec format error`, the image is not multi-arch.

### Phase 7 — Packer AMI

**Manual steps:**

- [ ] **7a.** Install Packer (see prerequisites).

- [ ] **7b.** In `furryman/terraform` GitHub repo settings: add GitHub Actions secrets (or configure OIDC role assumption):
  - `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for a CI IAM user with EC2 + AMI build permissions. (Or, modern: configure OpenID Connect with `aws-actions/configure-aws-credentials` so you don't store long-lived keys at all.)

- [ ] **7c.** First Packer build: run locally to validate before relying on CI.

  ```bash
  cd packer/
  packer init .
  packer validate k3s-portfolio.pkr.hcl
  packer build k3s-portfolio.pkr.hcl
  # Takes ~8-10 minutes
  ```

- [ ] **7d.** Verify the AMI appears in the EC2 console (`AMIs` view, filter by Owner=Self). It should have tags `ManagedBy=Packer`, `Version=<sha>`, `Cluster=fuhriman-k3s`.

- [ ] **7e.** After Task 7.5 (Terraform switches to consume the Packer AMI), `terraform apply` will recreate the instance. Same downtime expectations as Phase 4/6 reprovisions.

- [ ] **7f.** Validate cold-start improvement: stop the instance, start it, time from start to `kubectl get nodes` showing `Ready`. Should be ~30 seconds (vs ~5 minutes with the original user_data).

### Phase 8 — Documentation

**Manual steps:**

- [ ] **8a.** Read each updated README/CLAUDE.md after the agent rewrites them — confirm accuracy. Things to double-check:
  - The architecture ASCII diagram matches reality
  - Cost figures match what AWS Billing actually shows
  - Any URLs (ArgoCD UI, the website) are correct
  - The `terraform output ...` values cited match what your terraform actually outputs
- [ ] **8b.** Delete the old plan docs as listed in Phase 8.3: `git rm docs/plans/2026-02-16-*.md`. Commit.

---

## ✅ Section 3 — Things that need a wait window

These have unavoidable wait times. Schedule them when you can afford the delay.

| Action | Wait | Why |
|--------|------|-----|
| DNS NS-record propagation (Phase 3c) | 1–4 hours typical, up to 24 hours worst case | TTLs at parent NS servers; lower the existing Squarespace TTLs 24 hr before to shrink this |
| Let's Encrypt cert issuance (after Phase 4 cert-manager change) | 30–120 seconds | ACME challenge + LE rate-limit budget |
| EBS snapshot completion (Phase 5a) | 2–10 minutes for the first; subsequent incrementals are seconds | EBS snapshot creation is async |
| Instance reprovision (Phase 4, 6, 7) | 5–8 minutes | EC2 launch + k3s bootstrap + ArgoCD sync of all apps |
| Packer build (Phase 7c) | 8–10 minutes | Provisioner scripts + image creation |
| AMI snapshot dedup settling (Phase 7) | Hours to days for billing to reflect dedup | EBS billing is eventually consistent; expect 1–2 days for the snapshot storage cost to drop to the post-dedup number |

---

## ✅ Section 4 — Emergency contacts / rollback quick-reference

If something goes wrong mid-execution, here's where to look:

| Symptom | Quick action | Documentation |
|---------|--------------|---------------|
| `terraform apply` fails halfway | `terraform plan` to see current drift; resolve before re-applying | `README.md` |
| DNS records gone after NS cutover (Phase 3) | At Squarespace, toggle back from "custom nameservers" to default. (3–6 hours to fully restore.) | Phase 3 of the plan |
| ArgoCD UI unreachable after Phase 5 chart bump | `helm rollback argocd 1 -n argocd` via SSM shell | Phase 5 risk register row |
| EC2 instance unreachable after reprovision | Check the `aws ec2 describe-instance-status` output; if stuck, check cloud-init log via SSM: `sudo tail -f /var/log/k3s-init.log` | Phase 4/6/7 reprovision risks |
| Cert renewal failing | `kubectl describe challenges -A` to see the ACME error | Phase 4 risks |
| Lost local state somehow | Restore from S3 versioning: `aws s3api list-object-versions --bucket fuhriman-terraform-state`, then `aws s3api copy-object` the desired version | Phase 0 |

---

## ✅ Section 5 — Definition of done

You're finished with the entire migration when **all** of these are true:

- [ ] `https://fuhriman.org` loads with a green padlock (Let's Encrypt cert)
- [ ] `https://argocd.fuhriman.org` loads with a green padlock (Let's Encrypt cert)
- [ ] `aws ssm start-session --target <id>` opens a working shell
- [ ] `KUBECONFIG=~/.kube/portfolio-config kubectl get nodes` shows `Ready` on a `t4g.small` ARM instance
- [ ] `terraform plan` from a fresh checkout reports "no changes" (state is in S3 + locked)
- [ ] No public ingress on ports 22, 6443, or 30443 (`aws ec2 describe-security-groups`)
- [ ] `kubectl get all -A` shows no `Ingress` resources; routing is via `Gateway` + `HTTPRoute`
- [ ] `kubectl get configmap coredns-custom -n kube-system` exists and has the rewrite rules
- [ ] `aws dlm get-lifecycle-policy ...` shows the monthly schedule with retention=3
- [ ] `aws ec2 describe-images --owners self` shows your latest Packer AMI tagged `ManagedBy=Packer`
- [ ] AWS Billing dashboard for the next billing month shows ≤ $20 in EC2 + EBS + Route53 + DLM (plus the $3.65 fixed IPv4 charge)
- [ ] All four repos (`terraform`, `argocd-app-of-apps`, `eks-helm-charts`, `fuhriman-website`) have current READMEs matching what's deployed

When every box is checked, you're done. Take a screenshot of the green padlocks for the portfolio writeup.
