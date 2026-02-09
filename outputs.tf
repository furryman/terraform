output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "instance_id" {
  description = "The EC2 instance ID running k3s"
  value       = module.k3s.instance_id
}

output "instance_public_ip" {
  description = "The public IP of the k3s instance"
  value       = module.k3s.instance_public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the k3s instance"
  value       = module.k3s.ssh_command
}

output "kubeconfig_command" {
  description = "Command to retrieve kubeconfig from the instance"
  value       = module.k3s.kubeconfig_command
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = module.k3s.argocd_url
}
