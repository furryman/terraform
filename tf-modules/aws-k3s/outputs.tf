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
  value       = "scp ec2-user@${aws_instance.k3s.public_ip}:/etc/rancher/k3s/k3s.yaml ./k3s-kubeconfig.yaml && sed -i 's/127.0.0.1/${aws_instance.k3s.public_ip}/g' ./k3s-kubeconfig.yaml && export KUBECONFIG=./k3s-kubeconfig.yaml"
}

output "kubeconfig_setup" {
  description = "Steps to configure kubectl access"
  value       = <<-EOT
    1. Download kubeconfig: scp ec2-user@${aws_instance.k3s.public_ip}:/etc/rancher/k3s/k3s.yaml ./k3s-kubeconfig.yaml
    2. Update server IP: sed -i 's/127.0.0.1/${aws_instance.k3s.public_ip}/g' ./k3s-kubeconfig.yaml
    3. Add insecure skip (if needed): kubectl config set-cluster default --insecure-skip-tls-verify=true --kubeconfig=./k3s-kubeconfig.yaml
    4. Set KUBECONFIG: export KUBECONFIG=./k3s-kubeconfig.yaml
  EOT
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI"
  value       = "https://${aws_instance.k3s.public_ip}:30443"
}

output "argocd_password_command" {
  description = "Command to retrieve ArgoCD admin password"
  value       = "ssh ec2-user@${aws_instance.k3s.public_ip} \"sudo kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d\""
}

output "website_urls" {
  description = "URLs for the deployed website"
  value       = <<-EOT
    Production URLs:
    - https://fuhriman.org
    - https://www.fuhriman.org

    Note: Ensure DNS A/CNAME records point to ${aws_instance.k3s.public_ip}
  EOT
}
