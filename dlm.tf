# AWS Data Lifecycle Manager (DLM) — monthly EBS snapshots, retain 3.
#
# Cheaper and simpler than AWS Backup at this scale (no per-resource management
# fee; pure snapshot storage cost). Targets the k3s instance by its `Cluster`
# tag; INSTANCE resource type produces consistent multi-volume snapshots.
#
# Cost: ~$1.10/mo for 3 retained snapshots (~22 GB stored after dedup).

# Service role that DLM assumes to create snapshots.
resource "aws_iam_role" "dlm" {
  name = "${var.cluster_name}-dlm-lifecycle"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "dlm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

# AWS-managed policy granting DLM the EC2 snapshot permissions it needs.
resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# Lifecycle policy: monthly snapshots of any EC2 instance tagged with
# Cluster=<cluster_name>; retain the 3 most recent.
resource "aws_dlm_lifecycle_policy" "ebs_monthly" {
  # DLM description regex: [0-9A-Za-z _-]+ ; no parens, slashes, etc.
  description        = "Monthly snapshots of ${var.cluster_name} retain 3"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]

    target_tags = {
      Cluster = var.cluster_name
    }

    schedule {
      name = "monthly-retain-3"

      # interval/interval_unit only supports HOURS; for monthly use a cron expression.
      # AWS cron format: cron(min hour day-of-month month day-of-week year)
      # 04:00 UTC on day 1 of every month (~21:00 PDT, low-traffic window).
      create_rule {
        cron_expression = "cron(0 4 1 * ? *)"
      }

      retain_rule {
        count = 3
      }

      copy_tags = true

      tags_to_add = {
        SnapshotCreator = "DLM"
        Cluster         = var.cluster_name
      }
    }
  }

  tags = local.tags
}
