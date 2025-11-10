terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
    tls = { source = "hashicorp/tls" }
  }
}

locals {
  normalized_project = lower(replace(var.project_name, " ", "-"))
  cluster_name       = "${local.normalized_project}-lt"
  master_svc_name    = "${local.cluster_name}-master"
  worker_svc_name    = "${local.cluster_name}-worker"
  namespace_name     = "${local.normalized_project}.local"
  container_name     = "master"
  # Resolved IDs for BYO vs Create
  vpc_id_resolved = var.use_existing_vpc ? var.vpc_id : aws_vpc.lt[0].id
  public_subnet_ids_resolved = var.use_existing_subnets ? var.public_subnet_ids : [aws_subnet.public_a[0].id, aws_subnet.public_b[0].id]
}

data "aws_availability_zones" "available" {}

resource "aws_vpc" "lt" {
  count                = var.use_existing_vpc ? 0 : 1
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${local.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "lt" {
  count = var.use_existing_vpc || var.use_existing_igw ? 0 : 1
  vpc_id = aws_vpc.lt[0].id
  tags   = { Name = "${local.cluster_name}-igw" }
}

resource "aws_subnet" "public_a" {
  count                   = var.use_existing_subnets ? 0 : 1
  vpc_id                  = aws_vpc.lt[0].id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.cluster_name}-public-a" }
}

resource "aws_subnet" "public_b" {
  count                   = var.use_existing_subnets ? 0 : 1
  vpc_id                  = aws_vpc.lt[0].id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.cluster_name}-public-b" }
}

resource "aws_route_table" "public" {
  count = var.use_existing_subnets ? 0 : 1
  vpc_id = aws_vpc.lt[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lt[0].id
  }
  tags = { Name = "${local.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "a" {
  count          = var.use_existing_subnets ? 0 : 1
  subnet_id      = aws_subnet.public_a[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "b" {
  count          = var.use_existing_subnets ? 0 : 1
  subnet_id      = aws_subnet.public_b[0].id
  route_table_id = aws_route_table.public[0].id
}

# BYO: ensure public subnets have an associated route table; if none, associate main RT
data "aws_vpc" "byo" {
  count = var.use_existing_vpc ? 1 : 0
  id    = var.vpc_id
}

data "aws_route_tables" "by_subnet" {
  for_each = var.use_existing_subnets ? toset(var.public_subnet_ids) : []
  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

locals {
  byo_subnets_missing_rt = var.use_existing_subnets ? [
    for s in var.public_subnet_ids : s if length(try(data.aws_route_tables.by_subnet[s].ids, [])) == 0
  ] : []
}

resource "aws_route_table_association" "byo_assoc" {
  for_each      = toset(local.byo_subnets_missing_rt)
  subnet_id     = each.value
  route_table_id = data.aws_vpc.byo[0].main_route_table_id
}

resource "aws_security_group" "alb" {
  name        = "${local.cluster_name}-alb-sg"
  description = "ALB SG"
  vpc_id      = local.vpc_id_resolved
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
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
  tags = { Name = "${local.cluster_name}-alb-sg" }
}

resource "aws_security_group" "ecs" {
  name        = "${local.cluster_name}-ecs-sg"
  description = "ECS tasks SG"
  vpc_id      = local.vpc_id_resolved
  ingress {
    from_port       = var.master_port
    to_port         = var.master_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    from_port = 5557
    to_port   = 5558
    protocol  = "tcp"
    self      = true
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.cluster_name}-ecs-sg" }
}

resource "aws_lb" "this" {
  name               = "${local.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids_resolved
}

resource "aws_lb_target_group" "master" {
  name        = "${substr(local.cluster_name,0,20)}-tg"
  port        = var.master_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id_resolved
  target_type = "ip"
  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.master.arn
  }
}

resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "this" {
  private_key_pem = tls_private_key.this.private_key_pem
  subject {
    common_name  = "${local.cluster_name}.local"
    organization = "AutoMock"
  }
  validity_period_hours = 8760
  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "self" {
  private_key      = tls_private_key.this.private_key_pem
  certificate_body = tls_self_signed_cert.this.cert_pem
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.self.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.master.arn
  }
}

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.cluster_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.cluster_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name = local.namespace_name
  vpc  = local.vpc_id_resolved
}

resource "aws_service_discovery_service" "master" {
  name = "master"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_ecs_task_definition" "master" {
  family                   = local.master_svc_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu_units)
  memory                   = tostring(var.memory_units)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.locust_container_image
      essential = true
      portMappings = [{ containerPort = var.master_port, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "master"
        }
      }
    }
  ])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = local.worker_svc_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu_units)
  memory                   = tostring(var.memory_units)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = var.locust_container_image
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "worker"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "master" {
  name            = local.master_svc_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.master.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = local.public_subnet_ids_resolved
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.master.arn
    container_name   = local.container_name
    container_port   = var.master_port
  }
  service_registries { registry_arn = aws_service_discovery_service.master.arn }
  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "worker" {
  name            = local.worker_svc_name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"
  network_configuration {
    subnets         = local.public_subnet_ids_resolved
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = true
  }
}
