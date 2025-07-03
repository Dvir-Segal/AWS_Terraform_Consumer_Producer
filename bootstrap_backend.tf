# provider "aws" {
#   region     = var.region
#   access_key = var.aws_access_key_id
#   secret_key = var.aws_secret_access_key
# }

# resource "aws_s3_bucket" "state_bucket" {
#   bucket = var.terraform_state_bucket_name
# }

# resource "aws_dynamodb_table" "lock_table" {
#   name         = var.terraform_lock_table_name
#   billing_mode = "PAY_PER_REQUEST"
#   hash_key     = "LockID"

#   attribute {
#     name = "LockID"
#     type = "S"
#   }
# }

# output "s3_bucket_name" {
#   value = aws_s3_bucket.state_bucket.bucket
# }
# output "dynamodb_table_name" {
#   value = aws_dynamodb_table.lock_table.name
# }