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
