##############################################
# modules/automock-ecs/variables.tf
##############################################


variable "project_name" {
  description = "AutoMock project name (user-friendly identifier)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_size" {
  description = "ECS task size (small, medium, large, xlarge)"
  type        = string
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.instance_size)
    error_message = "Instance size must be one of: small, medium, large, xlarge."
  }
}

variable "min_tasks" {
  description = "Minimum number of ECS tasks (for load testing, use 10+)"
  type        = number
  default     = 10

  validation {
    condition     = var.min_tasks >= 1 && var.min_tasks <= 200
    error_message = "Minimum tasks must be between 1 and 200."
  }
}

variable "max_tasks" {
  description = "Maximum number of ECS tasks"
  type        = number
  default     = 200

  validation {
    condition     = var.max_tasks >= 1 && var.max_tasks <= 200
    error_message = "Maximum tasks must be between 1 and 200."
  }
}

variable "config_bucket_name" {
  description = "S3 bucket name for configuration (from external S3 module)"
  type        = string
  default     = ""
}

variable "config_bucket_arn" {
  description = "S3 bucket ARN for configuration"
  type        = string
  default     = ""
}

variable "s3_bucket_configuration" {
  description = "S3 bucket configuration details"
  type = object({
    bucket_name       = string
    metadata_path     = string
    versions_prefix   = string
  })
  default = null
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "cpu_units" {
  description = "CPU units for the ECS task definition"
  type        = number
  default     = 256
}

variable "memory_units" {
  description = "Memory (in MiB) for the ECS task definition"
  type        = number
  default     = 512
}


# ─────────────────────────────────────────────
# BYO networking toggles (default: OFF)
# ─────────────────────────────────────────────
variable "use_existing_vpc" {
  description = "If true, use an existing VPC instead of creating a new one."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Existing VPC ID when use_existing_vpc = true."
  type        = string
  default     = ""
}

variable "use_existing_subnets" {
  description = "If true, use existing subnets instead of creating new ones."
  type        = bool
  default     = false
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs (for ALB/NAT) when use_existing_subnets = true."
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (for ECS tasks) when use_existing_subnets = true."
  type        = list(string)
  default     = []
}

variable "use_existing_security_groups" {
  description = "If true, use existing security groups instead of creating new ones."
  type        = bool
  default     = false
}

# If you pass two IDs, we’ll treat index 0 as ALB SG, index 1 as ECS SG.
variable "security_group_ids" {
  description = "Existing SG IDs when use_existing_security_groups = true (0 = ALB, 1 = ECS)."
  type        = list(string)
  default     = []
}

# Optional BYO for egress resources (only if your current module creates these)
variable "use_existing_igw" {
  description = "If true, use an existing Internet Gateway (skip creating one)."
  type        = bool
  default     = false
}

variable "internet_gateway_id" {
  description = "Existing Internet Gateway ID when use_existing_igw = true."
  type        = string
  default     = ""
}

variable "use_existing_nat" {
  description = "If true, use existing NAT Gateway(s) (skip creating)."
  type        = bool
  default     = false
}

variable "nat_gateway_ids" {
  description = "Existing NAT Gateway IDs when use_existing_nat = true."
  type        = list(string)
  default     = []
}

# ─────────────────────────────────────────────
# BYO IAM roles (execution + task) ONLY
# ─────────────────────────────────────────────
variable "use_existing_iam_roles" {
  description = "If true, use existing IAM roles for task execution and task role."
  type        = bool
  default     = false
}

variable "task_execution_role_arn" {
  description = "Existing task execution role ARN when use_existing_iam_roles = true."
  type        = string
  default     = ""
}

variable "task_role_arn" {
  description = "Existing task role ARN when use_existing_iam_roles = true."
  type        = string
  default     = ""
}
