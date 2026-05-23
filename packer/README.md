# Packer AMI for fuhriman.org k3s portfolio

Builds an Amazon Linux 2023 ARM (Graviton) AMI with k3s, Helm, and kubectl pre-installed. The resulting AMI is consumed by `tf-modules/aws-k3s/main.tf` via a tag-filtered lookup.

This implements **Phase 7** of [`docs/plans/2026-05-22-modern-portfolio-architecture.md`](../docs/plans/2026-05-22-modern-portfolio-architecture.md).

## Layout

```text
packer/
├── k3s-portfolio.pkr.hcl   # Build configuration
├── packer-manifest.json    # Output (gitignored) — last build's AMI ID
├── scripts/
│   ├── install-k3s.sh      # k3s binary + systemd unit (NOT started)
│   └── install-helm.sh     # Helm + kubectl + repo cache
└── README.md
```

## What's in the AMI vs at runtime

| In the AMI (this Packer build) | At runtime (`user_data.sh`) |
|---|---|
| `k3s` binary + systemd unit | Start `k3s` with `--tls-san=<public-ip>` |
| `helm`, `kubectl` binaries | `helm install argocd argo/argo-cd --version ...` |
| Helm repo cache (`argo`, `jetstack`) | `helm install argocd-apps argo/argocd-apps ...` |
| IMDSv2-only base | Tail logs, exit cleanly |
| Build-time deps (curl, jq, tar) | (~30 lines vs ~120 today) |

## Build locally

Requires Packer 1.10+ and AWS credentials with EC2 permissions (see [the manual-steps doc](../docs/plans/2026-05-22-modern-portfolio-architecture-manual-steps.md)).

```bash
cd packer/
packer init .
packer validate .
packer build -var "git_sha=$(git rev-parse --short HEAD)" .
```

Expected build time: ~8–10 minutes. Output AMI ID is in `packer-manifest.json`.

## Build in CI

The workflow at `.github/workflows/build-ami.yml` triggers on push of a tag matching `packer-v*` and runs `packer build` with the git SHA stamped into the AMI tag.

After a successful CI build, the next `terraform apply` picks up the new AMI automatically (the AMI lookup in `tf-modules/aws-k3s/main.tf` uses `most_recent = true`).

## Versioning convention

Tag the repo to trigger a build:

```bash
git tag packer-v1.0.0
git push origin packer-v1.0.0
```

CI tags the AMI with the short SHA so you can correlate AMI ↔ source tree state.

## Cost

- **Build cost:** ~$0.003 per build (t4g.small for ~10 min)
- **AMI storage:** ~$0.05–0.50/mo per retained AMI, dedup-aware against the DLM EBS snapshots. The CI lifecycle step retains only the 3 most recent.

## Future enhancements (out of scope for first cut)

- **Image pre-pulling** — pre-pull cert-manager, envoy-gateway, argocd container images into the AMI to drop cold-start to ~30 sec. Requires briefly starting k3s during the build, pulling, and cleaning runtime state. Skipped here to keep the first cut simple; add `scripts/prepull-images.sh` when chasing the next round of cold-start improvements.
- **CIS hardening** — apply CIS AL2023 baseline (e.g., via OpenSCAP). Portfolio polish, not required.
- **Provisioner caching** — use Packer's `breakpoint` for iterative debugging during script development.
