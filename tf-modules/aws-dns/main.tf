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
