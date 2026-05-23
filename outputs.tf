output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "instance_id" {
  description = "The EC2 instance ID running k3s"
  value       = module.k3s.instance_id
}

output "instance_public_ip" {
  description = "The public IP (Elastic IP) of the k3s instance"
  value       = module.k3s.instance_public_ip
}

output "instance_private_ip" {
  description = "The private (VPC) IP of the k3s instance"
  value       = module.k3s.instance_private_ip
}

output "ssm_session_command" {
  description = "Open an interactive shell on the k3s instance via SSM Session Manager"
  value       = module.k3s.ssm_session_command
}

output "ssm_port_forward_kubectl_command" {
  description = "Open an SSM port-forward tunnel for kubectl. Run in a dedicated terminal."
  value       = module.k3s.ssm_port_forward_kubectl_command
}

output "kubeconfig_retrieval_command" {
  description = "One-time kubeconfig fetch via SSM. Saves to ~/.kube/portfolio-config."
  value       = module.k3s.kubeconfig_retrieval_command
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = module.k3s.argocd_url
}

output "argocd_password_command" {
  description = "Retrieve the initial ArgoCD admin password (requires SSM tunnel + KUBECONFIG)"
  value       = module.k3s.argocd_password_command
}

output "nameservers" {
  description = "Route53 NS records — paste these into the Squarespace registrar to delegate the domain. Cutover is irreversible-for-hours; lower existing record TTLs to 300s 24hrs before."
  value       = module.dns.name_servers
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID (used by ExternalDNS in-cluster to scope record management)"
  value       = module.dns.zone_id
}
