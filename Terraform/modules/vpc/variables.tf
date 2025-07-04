variable "region" {
  description = "The AWS region for deployment."
  type        = string
}

variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_az1_cidr" {
  description = "The CIDR block for the public subnet in AZ1."
  type        = string
  default     = "10.0.10.0/24"
}

variable "public_subnet_az2_cidr" {
  description = "The CIDR block for the public subnet in AZ2."
  type        = string
  default     = "10.0.20.0/24"
}