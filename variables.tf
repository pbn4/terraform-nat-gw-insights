variable "logs_retention_days" {
  description = "Number of days to retain logs in S3 bucket before automatic deletion"
  type        = number
  default     = 7
}

variable "nat_gateway_id" {
  description = "The ID of the NAT Gateway to create insights solution for"
  type        = string
}

variable "tags" {
  description = "A mapping of tags to assign to all resources"
  type        = map(string)
  default     = {}
}
