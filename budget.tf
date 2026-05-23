# AWS Budget Alert for cost governance
resource "aws_budgets_budget" "monthly" {
  name        = "${var.cluster_name}-monthly-budget"
  budget_type = "COST"
  # Bumped 25 → 40 in Phase 3.5: t4g.medium adds ~$15/mo vs t3.small; total
  # end-state ~$31.50/mo with EIP + Route53 + DLM + Packer AMI snapshots.
  # $40 gives a healthy 25% margin for future Helm chart bumps or extras.
  limit_amount = "40"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = toset([80, 100])
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }
}
