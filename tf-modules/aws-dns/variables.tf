variable "domain_name" {
  description = "Domain name for hosted zones"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to associate with the private hosted zone"
  type        = string
}

variable "instance_public_ip" {
  description = "EC2 public IP (EIP) for public DNS records"
  type        = string
}

variable "instance_private_ip" {
  description = "EC2 private IP for private DNS records"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
