variable "aws_access_key_id" {
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-west-1"
}

variable "producer_token" {
  description = "The secure token used by Microservice 1, stored in SSM"
  type        = string
  sensitive   = true
}

