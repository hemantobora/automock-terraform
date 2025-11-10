variable "project_name" { type = string }
variable "aws_region" { type = string }
variable "cpu_units" { type = number }
variable "memory_units" { type = number }
variable "worker_desired_count" { type = number }
variable "master_port" { type = number }
variable "log_retention_days" { type = number }
variable "locust_container_image" { type = string }

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
