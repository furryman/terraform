output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.public.zone_id
}

output "name_servers" {
  description = "Route53 NS records — paste these into the Squarespace registrar to delegate the domain"
  value       = aws_route53_zone.public.name_servers
}

output "zone_arn" {
  description = "Route53 hosted zone ARN (for IAM policy scoping)"
  value       = aws_route53_zone.public.arn
}
