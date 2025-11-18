# terraform/modules/automock-ecs/outputs.tf
# Output Values for AutoMock ECS Module (BYO-aware)

output "public_alb_dns_name" {
  description = "DNS name of the public ALB (if enabled)"
  value       = length(aws_lb.main) > 0 ? aws_lb.main[0].dns_name : null
}

output "private_alb_dns_name" {
  description = "DNS name of the private ALB (if enabled)"
  value       = length(aws_lb.private) > 0 ? aws_lb.private[0].dns_name : null
}

output "public_alb_zone_id" {
  description = "Zone ID of the public ALB (if enabled)"
  value       = length(aws_lb.main) > 0 ? aws_lb.main[0].zone_id : null
}

output "private_alb_zone_id" {
  description = "Zone ID of the private ALB (if enabled)"
  value       = length(aws_lb.private) > 0 ? aws_lb.private[0].zone_id : null
}

output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.main.arn
}

output "service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.mockserver.name
}

output "service_arn" {
  description = "ARN of the ECS service"
  value       = aws_ecs_service.mockserver.id
}

output "task_definition_arn" {
  description = "ARN of the ECS task definition"
  value       = aws_ecs_task_definition.mockserver.arn
}

output "vpc_id" {
  description = "ID of the VPC (BYO-aware)"
  value       = local.vpc_id_resolved
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (BYO-aware)"
  value       = local.public_subnet_ids_resolved
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (BYO-aware)"
  value       = local.private_subnet_ids_resolved
}

output "alb_security_group_id" {
  description = "ID of the ALB security group (BYO-aware)"
  value       = local.alb_security_group_id_resolved
}

output "ecs_security_group_id" {
  description = "ID of the ECS tasks security group (BYO-aware)"
  value       = local.ecs_security_group_ids_resolved[0]
}

output "config_bucket" {
  description = "S3 bucket name for configuration"
  value       = local.s3_config.bucket_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "project_name" {
  description = "Project name"
  value       = var.project_name
}

# Friendly summary (always HTTPS, since 80->443 redirect + cert)
output "infrastructure_summary" {
  description = "Complete infrastructure summary"
  value = {
    project  = var.project_name
    region   = var.region
    endpoints = {
      api       = "https://${aws_lb.main[0].dns_name}"
      dashboard = "https://${aws_lb.main[0].dns_name}/mockserver/dashboard"
    }
    compute = {
      instance_size  = try(var.instance_size, "")  # if not defined, empty string
      min_tasks      = var.min_tasks
      max_tasks      = var.max_tasks
      current_tasks  = var.min_tasks
    }
  }
}

output "cli_integration_commands" {
  description = "CLI commands for integration and management"
  value = {
    health_check       = "curl https://${aws_lb.main[0].dns_name}/health"
    list_expectations  = "curl https://${aws_lb.main[0].dns_name}/mockserver/expectation"
    view_logs          = "aws logs tail /ecs/automock/${var.project_name}/mockserver --follow --region ${var.region}"
    scale_service      = "aws ecs update-service --cluster ${aws_ecs_cluster.main.name} --service ${aws_ecs_service.mockserver.name} --desired-count <COUNT> --region ${var.region}"
  }
}

output "integration_summary" {
  description = "Integration details for S3 bucket and configuration"
  value = {
    s3_bucket         = local.s3_config.bucket_name
    metadata_path     = local.s3_config.metadata_path
    versions_prefix   = local.s3_config.versions_prefix
  }
}

output "mockserver_url" {
  description = "URL to access the MockServer API"
  value       = "https://${aws_lb.main[0].dns_name}"
}

output "dashboard_url" {
  description = "URL to access the MockServer Dashboard"
  value       = "https://${aws_lb.main[0].dns_name}/mockserver/dashboard"
}
