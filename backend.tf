# Terraform Backend Configuration
# Stores state in S3 with DynamoDB locking

terraform {
  backend "s3" {
    bucket         = "fuhriman-terraform-state"
    key            = "eks/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}

# NOTE: Before running terraform init, you must create:
# 1. S3 bucket: fuhriman-terraform-state
#    - Enable versioning
#    - Enable server-side encryption
#    - Block public access
#
# 2. DynamoDB table: terraform-state-lock
#    - Partition key: LockID (String)
#
# You can create these manually or comment out this backend block
# to use local state initially, then migrate later.
