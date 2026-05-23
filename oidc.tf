# GitHub Actions OIDC trust setup
#
# Lets the .github/workflows/build-ami.yml workflow assume an IAM role to run
# Packer builds — without long-lived AWS access keys. The role is restricted
# to GitHub Actions runs originating from the furryman/terraform repo.

# AWS OIDC provider trusting GitHub's token issuer.
# Thumbprints from https://github.blog/changelog/2023-06-27-github-actions-update-on-oidc-integration-with-aws/
# (rotated occasionally; the second value is a fallback).
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = local.tags
}

# IAM role assumable by the build-ami.yml workflow.
resource "aws_iam_role" "github_actions_packer" {
  name = "github-actions-packer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to this repo only. Any branch, any ref type (push, tag,
          # workflow_dispatch).
          "token.actions.githubusercontent.com:sub" = "repo:furryman/terraform:*"
        }
      }
    }]
  })

  tags = local.tags
}

# Permissions needed by Packer's amazon-ebs builder + AMI lifecycle cleanup
# (deregister-image, delete-snapshot for retention policy).
resource "aws_iam_role_policy" "github_actions_packer" {
  name = "packer-build"
  role = aws_iam_role.github_actions_packer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PackerEC2Build"
        Effect = "Allow"
        Action = [
          # Instance lifecycle (Packer launches a temporary builder)
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:StopInstances",
          "ec2:GetPasswordData",
          "ec2:ModifyInstanceAttribute",

          # Read access (Packer queries available resources)
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeImages",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeRegions",
          "ec2:DescribeKeyPairs",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeVolumes", # Packer cleanup queries this

          # AMI lifecycle
          "ec2:CreateImage",
          "ec2:DeregisterImage",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
          "ec2:CopyImage",
          "ec2:CreateTags",

          # Temporary SSH key Packer generates
          "ec2:CreateKeyPair",
          "ec2:DeleteKeyPair",

          # Temporary SG Packer generates
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
        ]
        Resource = "*"
      }
    ]
  })
}
