# terraform/modules/automock-ecs/outputs.tf
# Output Values for AutoMock ECS Module (BYO-aware)

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
      api_tls            = "https://${aws_lb.main.dns_name}"
      dashboard_tls      = "https://${aws_lb.main.dns_name}/mockserver/dashboard"
      internal_api_tls   = length(aws_lb.private) > 0 ? "https://${aws_lb.private[0].dns_name}" : "Not enabled"
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
    health_check       = "curl https://${aws_lb.main.dns_name}/health"
    list_expectations  = "curl https://${aws_lb.main.dns_name}/mockserver/expectation"
    view_logs          = "aws logs tail /ecs/automock/${var.project_name}/mockserver --follow --region ${var.region}"
    scale_service      = "aws ecs update-service --cluster ${aws_ecs_cluster.main.name} --service ${aws_ecs_service.mockserver.name} --desired-count <COUNT> --region ${var.region}"
  }
}

output "secure_mockserver_url" {
  description = "URL to access the MockServer API"
  value       = "https://${aws_lb.main.dns_name}"
}

output "secure_dashboard_url" {
  description = "URL to access the MockServer Dashboard"
  value       = "https://${aws_lb.main.dns_name}/mockserver/dashboard"
}


output "mockserver_url" {
  description = "URL to access the MockServer API"
  value       = "http://${aws_lb.main.dns_name}"
}

output "dashboard_url" {
  description = "URL to access the MockServer Dashboard"
  value       = "http://${aws_lb.main.dns_name}/mockserver/dashboard"
}