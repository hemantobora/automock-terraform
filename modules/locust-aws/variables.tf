variable "project_name" { type = string }
variable "aws_region" { type = string }
variable "existing_bucket_name" { type = string }
## Sizing (split master vs worker)
variable "master_cpu_units" {
	type    = number
	default = 1024
}

variable "master_memory_units" {
	type    = number
	default = 2048
}

variable "worker_cpu_units" {
	type    = number
	default = 256
}

variable "worker_memory_units" {
	type    = number
	default = 512
}
variable "worker_desired_count" { type = number }
variable "master_port" { type = number }
variable "log_retention_days" { type = number }
variable "locust_container_image" { type = string }

variable "init_container_image" {
	type    = string
	default = "python:3.11-slim"
}

# BYO networking toggles (align with mockserver module)
variable "use_existing_vpc" {
	type        = bool
	description = "If true, use an existing VPC instead of creating a new one."
	default     = false
}

variable "vpc_id" {
	type        = string
	description = "Existing VPC ID when use_existing_vpc = true"
	default     = ""
}

variable "use_existing_subnets" {
	type        = bool
	description = "If true, use existing subnets instead of creating new ones."
	default     = false
}

variable "public_subnet_ids" {
	type        = list(string)
	description = "Existing public subnet IDs when use_existing_subnets = true"
	default     = []
}

# Optional BYO IGW/NAT inputs (we don't create NAT in this module)
variable "use_existing_igw" {
	type        = bool
	description = "If true, use an existing Internet Gateway (skip creating one)."
	default     = false
}

variable "internet_gateway_id" {
	type        = string
	description = "Existing Internet Gateway ID when use_existing_igw = true"
	default     = ""
}

# BYO IAM roles: allow using pre-created IAM roles instead of creating within module
variable "use_existing_iam_roles" {
	type        = bool
	description = "If true, use provided IAM role ARNs for task execution & task role; skip creating roles."
	default     = false
}

variable "execution_role_arn" {
	type        = string
	description = "Existing ECS task execution role ARN when use_existing_iam_roles = true"
	default     = ""
}

variable "task_role_arn" {
	type        = string
	description = "Existing ECS task role ARN when use_existing_iam_roles = true"
	default     = ""
}

# BYO Security Groups for ALB and ECS tasks
variable "use_existing_security_groups" {
	type        = bool
	description = "If true, use provided security group IDs for ALB and ECS tasks; skip creating them."
	default     = false
}

variable "alb_security_group_id" {
	type        = string
	description = "Existing ALB security group ID when use_existing_security_groups = true"
	default     = ""
}

variable "ecs_security_group_id" {
	type        = string
	description = "Existing ECS tasks security group ID when use_existing_security_groups = true"
	default     = ""
}

# Arbitrary environment variables for master and worker containers
variable "extra_environment" {
  type        = map(string)
  description = "Map of KEY => VALUE environment variables added to both master and worker containers. Values are stored in task definition (not encrypted)."
  default     = {}
}
