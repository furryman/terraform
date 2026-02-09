# AWS k3s Module
# Creates a single EC2 instance running k3s with ArgoCD

# Latest Amazon Linux 2023 AMI (free tier eligible)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# SSH Key Pair
resource "aws_key_pair" "k3s" {
  key_name   = "${var.cluster_name}-k3s-key"
  public_key = var.ssh_public_key

  tags = var.tags
}

# Security Group
resource "aws_security_group" "k3s" {
  name        = "${var.cluster_name}-k3s-sg"
  description = "Security group for k3s instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "k3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

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
    cidr_blocks = ["0.0.0.0/0"]
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
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k3s.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s.name

  associate_public_ip_address = true

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

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
