# AWS k3s Module
# Creates a single EC2 instance running k3s with ArgoCD

locals {
  # Pinned AMI: AL2023 x86_64. This is the AMI the live k3s instance was
  # originally built from — pinning to the runtime value (not the latest)
  # so removing `ignore_changes = [ami]` is a true no-op.
  # Bump explicitly when a new image is needed — do not float.
  # Phase 6 switches this to AL2023 arm64; Phase 7 to a Packer-built AMI.
  amazon_linux_ami = "ami-00eb2fff34909df65"
}

# No SSH key pair — admin access is via SSM Session Manager only.
# See outputs.tf for the SSM commands.

# Security Group
resource "aws_security_group" "k3s" {
  name        = "${var.cluster_name}-k3s-sg"
  description = "Security group for k3s instance"
  vpc_id      = var.vpc_id

  # Ports 22 (SSH) and 6443 (k3s API) intentionally NOT exposed.
  # Admin access via SSM Session Manager only; kubectl via SSM port-forward.
  # See outputs `ssm_session_command` and `ssm_port_forward_kubectl_command`.

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ArgoCD NodePort"
    from_port   = 30443
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-k3s-sg"
  })
}

# IAM Role for SSM access
resource "aws_iam_role" "k3s" {
  name = "${var.cluster_name}-k3s-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.k3s.name
}

resource "aws_iam_instance_profile" "k3s" {
  name = "${var.cluster_name}-k3s-profile"
  role = aws_iam_role.k3s.name

  tags = var.tags
}

# EC2 Instance running k3s
resource "aws_instance" "k3s" {
  ami                    = local.amazon_linux_ami
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s.name

  associate_public_ip_address = true

  # Enforce IMDSv2 (token-required) — hardens against SSRF that could otherwise
  # reach the instance metadata service. hop_limit=2 leaves room for pod-network
  # access to IMDS (ExternalDNS will use this in Phase 3).
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data_base64 = base64encode(templatefile("${path.module}/user_data.sh", {
    app_of_apps_repo_url = var.app_of_apps_repo_url
    argocd_chart_version = var.argocd_chart_version
  }))

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-k3s"
  })
}
