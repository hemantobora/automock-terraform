# terraform/modules/automock-ecs/main.tf
# AutoMock ECS Fargate + ALB + S3 Infrastructure Module

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0"
}

##############################################
# Locals / Tags
##############################################
locals {
  name_prefix = "auto-mock-${var.project_name}"

  cpu_units    = var.cpu_units
  memory_units = var.memory_units

  common_tags = {
    Project     = "AutoMock"
    ProjectName = var.project_name
    ManagedBy   = "Terraform"
    CreatedAt   = timestamp()
    Region      = var.region
  }

  # ── BYO toggles (non-invasive) ──────────────────────────────
  create_vpc             = !var.use_existing_vpc
  create_subnets         = !var.use_existing_subnets
  create_security_groups = !var.use_existing_security_groups
  create_igw             = !var.use_existing_igw
  create_nat             = !var.use_existing_nat
  create_log_group       = true

  # ECS infra remains create-only in this module (per your design)
  create_ecs_infra = true

  # IAM roles: BYO allowed (handled in iam.tf)
  use_byo_iam_roles = var.use_existing_iam_roles
}

##############################################
# ID resolution (BYO vs Create)
##############################################
locals {
  # VPC
  vpc_id_resolved = var.use_existing_vpc? var.vpc_id : try(aws_vpc.main[0].id, "")

  # Subnets
  public_subnet_ids_resolved = var.use_existing_subnets ? var.public_subnet_ids : try(aws_subnet.public[*].id, [])

  private_subnet_ids_resolved = var.use_existing_subnets ? var.private_subnet_ids : try(aws_subnet.private[*].id, [])

  # Internet Gateway
  igw_id_resolved = var.use_existing_igw ? var.internet_gateway_id : try(aws_internet_gateway.main[0].id, "")

  # NAT Gateway(s)
  nat_gateway_ids_resolved = var.use_existing_nat ? var.nat_gateway_ids : try(aws_nat_gateway.main[*].id, [])

  # Security Groups (index 0 = ALB, index 1 = ECS)
  alb_security_group_id_resolved = ( var.use_existing_security_groups && length(var.security_group_ids) > 0 ) ? var.security_group_ids[0] : try(aws_security_group.alb[0].id, "")

  ecs_security_group_ids_resolved = ( var.use_existing_security_groups && length(var.security_group_ids) > 1 ) ? [var.security_group_ids[1]] : [try(aws_security_group.ecs_tasks[0].id, "")]
}

##############################################
# Random suffix (for unique names when needed)
##############################################
resource "random_id" "suffix" {
  byte_length = 4
}

##############################################
# Data sources
##############################################
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Existing VPC data (only when BYO VPC)
data "aws_vpc" "existing" {
  count = var.use_existing_vpc ? 1 : 0
  id    = var.vpc_id
}

##############################################
# S3 configuration (passed from root or fallback name)
##############################################
locals {
  config_bucket_name = var.config_bucket_name != "" ? var.config_bucket_name : "${local.name_prefix}-config-${random_id.suffix.hex}"
  config_bucket_arn  = var.config_bucket_arn != "" ? var.config_bucket_arn : "arn:aws:s3:::${local.config_bucket_name}"

  # Shape expected by ecs.tf task envs (unchanged)
  s3_config = var.s3_bucket_configuration != null ? var.s3_bucket_configuration : {
    bucket_name       = local.config_bucket_name
    expectations_path = "expectations.json"
    metadata_path     = "project-metadata.json"
    versions_prefix   = "versions/"
  }
}

# ===================================================================
# NETWORKING (created only when BYO is OFF)
# ===================================================================

# VPC
resource "aws_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count = local.create_igw ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# Public Subnets (for ALB)
resource "aws_subnet" "public" {
  count = local.create_subnets ? 2 : 0

  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Type = "Public"
  })
}

# Private Subnets (for ECS tasks)
resource "aws_subnet" "private" {
  count = local.create_subnets ? 2 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${count.index + 1}"
    Type = "Private"
  })
}

# Single NAT (cost-optimized)
resource "aws_eip" "nat" {
  count = local.create_nat ? 1 : 0

  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip"
  })
}

resource "aws_nat_gateway" "main" {
  count = local.create_nat ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat"
  })
}

# Route tables
resource "aws_route_table" "public" {
  count = local.create_subnets ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table" "private" {
  count = local.create_subnets ? 2 : 0

  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt-${count.index + 1}"
  })
}

# Associations
resource "aws_route_table_association" "public" {
  count = local.create_subnets ? 2 : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count = local.create_subnets ? 2 : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ===================================================================
# SECURITY GROUPS (created only when BYO SGs are NOT provided)
# ===================================================================

resource "aws_security_group" "alb" {
  count = local.create_security_groups ? 1 : 0

  name_prefix = "${local.name_prefix}-alb-"
  vpc_id      = local.vpc_id_resolved

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb-sg" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "ecs_tasks" {
  count = local.create_security_groups ? 1 : 0

  name_prefix = "${local.name_prefix}-ecs-"
  vpc_id      = local.vpc_id_resolved

  # Expose ONLY port 1080 from ALB to tasks (API + UI on same port)
  ingress {
    description     = "MockServer (API+UI) over 1080 from ALB"
    from_port       = 1080
    to_port         = 1080
    protocol        = "tcp"
    security_groups = [local.alb_security_group_id_resolved]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecs-sg" })

  lifecycle { create_before_destroy = true }
}

# ===================================================================
# ALB & TG (Listeners and certs are in ssl.tf; keep it there)
# ===================================================================

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [local.alb_security_group_id_resolved]
  subnets         = local.public_subnet_ids_resolved

  enable_deletion_protection = false

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_lb_target_group" "mockserver_api" {
  name        = "${local.name_prefix}-api-tg"
  port        = 1080
  protocol    = "HTTP"
  vpc_id      = local.vpc_id_resolved
  target_type = "ip"

  deregistration_delay = 10

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/health"
    matcher             = "200-399"
    port                = "traffic-port"
    protocol            = "HTTP"
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-api-tg" })

  lifecycle { create_before_destroy = true }
}
