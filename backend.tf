# Terraform Backend Configuration
# Stores state in S3 with native S3 locking (use_lockfile).
# DynamoDB-based locking is deprecated as of Terraform 1.15+ — no separate lock table needed.

terraform {
  backend "s3" {
    bucket       = "fuhriman-terraform-state"
    key          = "k3s/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

# Provision the bucket once before `terraform init -migrate-state`:
#   aws s3api create-bucket --bucket fuhriman-terraform-state --region us-west-2 \
#       --create-bucket-configuration LocationConstraint=us-west-2
#   aws s3api put-bucket-versioning --bucket fuhriman-terraform-state \
#       --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket fuhriman-terraform-state \
#       --server-side-encryption-configuration \
#       '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws s3api put-public-access-block --bucket fuhriman-terraform-state \
#       --public-access-block-configuration \
#       BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
