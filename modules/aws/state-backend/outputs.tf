# terraform/modules/state-backend/outputs.tf

output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_locks.id
}

output "lock_table_arn" {
  description = "ARN of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_locks.arn
}

output "region" {
  description = "AWS region where state backend is deployed"
  value       = data.aws_region.current.name
}

output "backend_config" {
  description = "Backend configuration block for project terraform files"
  value = {
    bucket         = aws_s3_bucket.terraform_state.id
    region         = data.aws_region.current.name
    encrypt        = true
    dynamodb_table = aws_dynamodb_table.terraform_locks.id
  }
}
