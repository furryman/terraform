output "instance_id" {
  description = "The ID of the k3s EC2 instance"
  value       = aws_instance.k3s.id
}

output "instance_public_ip" {
  description = "The public IP (Elastic IP) of the k3s instance"
  value       = aws_eip.k3s.public_ip
}

output "instance_private_ip" {
  description = "The private (VPC) IP of the k3s instance"
  value       = aws_instance.k3s.private_ip
}

output "instance_public_dns" {
  description = "The public DNS of the k3s instance"
  value       = aws_instance.k3s.public_dns
}

output "security_group_id" {
  description = "Security group ID for the k3s instance"
  value       = aws_security_group.k3s.id
}

output "iam_role_name" {
  description = "IAM role name attached to the k3s instance — for additional policy attachments (e.g., ExternalDNS Route53 access)"
  value       = aws_iam_role.k3s.name
}

output "ssm_session_command" {
  description = "Open an interactive shell on the instance via SSM Session Manager"
  value       = "aws ssm start-session --target ${aws_instance.k3s.id} --profile portfolio --region us-west-2"
}

output "ssm_port_forward_kubectl_command" {
  description = "Open an SSM port-forward tunnel for kubectl. Run this in a dedicated terminal; then in another: KUBECONFIG=~/.kube/portfolio-config kubectl get nodes"
  value       = "aws ssm start-session --target ${aws_instance.k3s.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=6443,localPortNumber=6443 --profile portfolio --region us-west-2"
}

output "kubeconfig_retrieval_command" {
  description = "One-time kubeconfig fetch via SSM (k3s admin creds — handle with care). Saves to ~/.kube/portfolio-config; server stays at 127.0.0.1:6443 (works as-is via the SSM tunnel)."
  value       = <<-EOT
    mkdir -p ~/.kube && \
    CMD_ID=$(aws ssm send-command \
      --instance-ids ${aws_instance.k3s.id} \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["sudo cat /etc/rancher/k3s/k3s.yaml"]' \
      --profile portfolio --region us-west-2 \
      --query 'Command.CommandId' --output text) && \
    sleep 5 && \
    aws ssm get-command-invocation \
      --command-id $CMD_ID \
      --instance-id ${aws_instance.k3s.id} \
      --profile portfolio --region us-west-2 \
      --query 'StandardOutputContent' --output text > ~/.kube/portfolio-config && \
    chmod 600 ~/.kube/portfolio-config && \
    echo "kubeconfig saved. In one terminal: $(terraform output -raw ssm_port_forward_kubectl_command). In another: KUBECONFIG=~/.kube/portfolio-config kubectl get nodes"
  EOT
}

output "argocd_url" {
  description = "URL to access the ArgoCD UI (current — Phase 5 moves this to https://argocd.fuhriman.org)"
  value       = "https://${aws_instance.k3s.public_ip}:30443"
}

output "argocd_password_command" {
  description = "Retrieve initial ArgoCD admin password. Assumes the SSM port-forward tunnel is running and KUBECONFIG=~/.kube/portfolio-config is exported."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
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
