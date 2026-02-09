output "instance_id" {
  description = "The ID of the k3s EC2 instance"
  value       = aws_instance.k3s.id
}

output "instance_public_ip" {
  description = "The public IP of the k3s instance"
  value       = aws_instance.k3s.public_ip
}

output "instance_public_dns" {
  description = "The public DNS of the k3s instance"
  value       = aws_instance.k3s.public_dns
}

output "security_group_id" {
  description = "Security group ID for the k3s instance"
  value       = aws_security_group.k3s.id
}

output "ssh_command" {
  description = "SSH command to connect to the k3s instance"
  value       = "ssh ec2-user@${aws_instance.k3s.public_ip}"
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig from the k3s instance"
  value       = "scp ec2-user@${aws_instance.k3s.public_ip}:/etc/rancher/k3s/k3s.yaml ./k3s-kubeconfig.yaml && sed -i 's/127.0.0.1/${aws_instance.k3s.public_ip}/g' ./k3s-kubeconfig.yaml"
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = "https://${aws_instance.k3s.public_ip}:30443"
}
