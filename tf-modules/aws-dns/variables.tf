variable "domain_name" {
  description = "Domain name for the Route53 hosted zone (e.g., fuhriman.org)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "Must be a valid lowercase DNS domain (e.g., fuhriman.org)."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
