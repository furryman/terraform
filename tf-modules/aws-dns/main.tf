# AWS DNS Module
# Public Route53 hosted zone for the portfolio domain.
# Single public zone (no split-horizon) — hairpin NAT is handled at the
# cluster DNS layer (coredns-custom rewrite, Phase 4), not via a private zone.

resource "aws_route53_zone" "public" {
  name    = var.domain_name
  comment = "Public hosted zone for ${var.domain_name} — managed by Terraform"

  tags = merge(var.tags, {
    Name = "${var.domain_name}-public"
  })
}
