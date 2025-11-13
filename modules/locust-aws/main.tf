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
  exec_role_arn_resolved = var.use_existing_iam_roles ? var.execution_role_arn : aws_iam_role.task_execution[0].arn
  task_role_arn_resolved = var.use_existing_iam_roles ? var.task_role_arn      : aws_iam_role.task_execution[0].arn
  alb_sg_id_resolved  = var.use_existing_security_groups ? var.alb_security_group_id : aws_security_group.alb[0].id
  ecs_sg_id_resolved  = var.use_existing_security_groups ? var.ecs_security_group_id : aws_security_group.ecs[0].id
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
  count       = var.use_existing_security_groups ? 0 : 1
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
  count       = var.use_existing_security_groups ? 0 : 1
  name        = "${local.cluster_name}-ecs-sg"
  description = "ECS tasks SG"
  vpc_id      = local.vpc_id_resolved
  ingress {
    from_port       = var.master_port
    to_port         = var.master_port
    protocol        = "tcp"
    security_groups = [local.alb_sg_id_resolved]
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
  security_groups    = [local.alb_sg_id_resolved]
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
  count              = var.use_existing_iam_roles ? 0 : 1
  name               = "${local.cluster_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  count      = var.use_existing_iam_roles ? 0 : 1
  role       = aws_iam_role.task_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Minimal S3 read permissions for init sidecar to fetch the active bundle
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid     = "AllowGetObject"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.existing_bucket_name}/*",
    ]
  }
  statement {
    sid       = "AllowListBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.existing_bucket_name}"]
  }
  statement {
    sid       = "AllowBucketDecryption"
    actions   = ["kms:Decrypt","kms:DescribeKey"]
    resources = ["arn:aws:kms:*:*:key/*","arn:aws:kms:*:*:alias/auto-mock-*"]
  }  
}

resource "aws_iam_policy" "s3_read" {
  count  = var.use_existing_iam_roles ? 0 : 1
  name   = "${local.cluster_name}-s3-read"
  policy = data.aws_iam_policy_document.s3_read.json
}

resource "aws_iam_role_policy_attachment" "s3_read_attach" {
  count      = var.use_existing_iam_roles ? 0 : 1
  role       = aws_iam_role.task_execution[0].name
  policy_arn = aws_iam_policy.s3_read[0].arn
}

resource "aws_cloudwatch_log_group" "master" {
  name              = "/ecs/${local.cluster_name}/master"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.cluster_name}/worker"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name
}

locals {
  # Shell snippet used by the init sidecar to install boto3 and download the active bundle into /workspace
  init_bootstrap_shell = <<-EOT
  set -e
  pip install --no-cache-dir -q boto3
  python - <<'PY'
import os, sys, json
from typing import Optional
import boto3
from botocore.exceptions import BotoCoreError, ClientError

bucket = os.environ.get("BUNDLE_BUCKET")
project = os.environ.get("PROJECT_NAME")
if not bucket or not project:
  print("[bootstrap] Missing BUNDLE_BUCKET or PROJECT_NAME env vars", file=sys.stderr)
  sys.exit(0)

pointer_key = f"configs/{project}-loadtest/current.json"
bundle_prefix_base = f"configs/{project}-loadtest/bundles"
workspace = "/workspace"
os.makedirs(workspace, exist_ok=True)

try:
  s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION"))
except Exception as e:
  print(f"[bootstrap] Failed to create S3 client: {e}", file=sys.stderr)
  sys.exit(0)

def get_pointer() -> Optional[dict]:
  try:
    s3.download_file(bucket, pointer_key, os.path.join(workspace, "current.json"))
    with open(os.path.join(workspace, "current.json"), "r", encoding="utf-8") as f:
      return json.load(f)
  except ClientError as e:
    if e.response.get("Error", {}).get("Code") == "NoSuchKey":
      print("[bootstrap] current.json not found; skipping.")
      return None
    print(f"[bootstrap] Error downloading pointer: {e}")
    return None
  except Exception as e:
    print(f"[bootstrap] Unexpected pointer error: {e}")
    return None

ptr = get_pointer()
if not ptr:
  sys.exit(0)

bundle_id = ptr.get("bundle_id") or ptr.get("BundleID")
if not bundle_id:
  print("[bootstrap] Pointer missing bundle_id; exiting.")
  sys.exit(0)

bundle_prefix = f"{bundle_prefix_base}/{bundle_id}/"
print(f"[bootstrap] bundle_id={bundle_id} prefix={bundle_prefix}")

paginator = s3.get_paginator("list_objects_v2")
count = 0
try:
  for page in paginator.paginate(Bucket=bucket, Prefix=bundle_prefix):
    for obj in page.get("Contents", []):
      key = obj["Key"]
      name = key.split("/")[-1]
      target = os.path.join(workspace, name)
      try:
        s3.download_file(bucket, key, target)
        count += 1
        print(f"[bootstrap] fetched {key} -> {target}")
      except (BotoCoreError, ClientError) as e:
        print(f"[bootstrap] failed {key}: {e}")
except Exception as e:
  print(f"[bootstrap] Unexpected list error: {e}")

print(f"[bootstrap] downloaded {count} bundle objects")
sys.exit(0)
PY
  # Install Python dependencies from the bundle into a shared path if present
  if [ -f /workspace/requirements.txt ]; then
    echo "[bootstrap] installing Python deps from requirements.txt into /workspace/.deps"
    python -m pip install --no-cache-dir --disable-pip-version-check --root-user-action=ignore -r /workspace/requirements.txt --target /workspace/.deps
  fi
  EOT
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
  cpu                      = tostring(var.master_cpu_units)
  memory                   = tostring(var.master_memory_units)
  execution_role_arn       = local.exec_role_arn_resolved
  task_role_arn            = local.task_role_arn_resolved
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  # Shared ephemeral volume for init<->master container to exchange bundle files
  volume { name = "workspace" }
  # Two containers:
  # 1. init sidecar that downloads current.json & bundle files from S3
  # 2. locust master container started after files are in place
  container_definitions = jsonencode([
    {
      name      = "init"
      image     = var.init_container_image
      essential = false
      mountPoints = [{ sourceVolume = "workspace", containerPath = "/workspace" }]
      command = ["sh","-lc", local.init_bootstrap_shell]
      environment = concat([
        { name = "AWS_REGION",    value = var.aws_region },
        { name = "BUNDLE_BUCKET", value = var.existing_bucket_name },
        { name = "PROJECT_NAME",  value = var.project_name }
      ], [for k, v in var.extra_environment : { name = k, value = v }])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.master.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "init-master"
        }
      }
    },
    {
      name      = local.container_name
      image     = var.locust_container_image
      essential = true
      mountPoints = [{ sourceVolume = "workspace", containerPath = "/workspace" }]
      workingDirectory = "/workspace"
      dependsOn = [{ containerName = "init", condition = "SUCCESS" }]
      portMappings = [
        { containerPort = var.master_port, protocol = "tcp" },
        { containerPort = 5557,            protocol = "tcp" },
        { containerPort = 5558,            protocol = "tcp" }
      ]
      # Since the Locust image has ENTRYPOINT ["locust"], command provides only arguments
  command = ["-f","/workspace/locustfile.py","--master","--master-bind-host","0.0.0.0","--master-bind-port","5557","--web-host","0.0.0.0","--web-port",tostring(var.master_port),"--loglevel","INFO"]
      environment = concat([
        { name = "LOCUST_MODE", value = "master" },
        { name = "LOCUST_LOGLEVEL", value = "INFO" },
        { name = "PYTHONPATH", value = "/workspace/.deps" }
      ], [for k, v in var.extra_environment : { name = k, value = v }])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.master.name
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
  cpu                      = tostring(var.worker_cpu_units)
  memory                   = tostring(var.worker_memory_units)
  execution_role_arn       = local.exec_role_arn_resolved
  task_role_arn            = local.task_role_arn_resolved
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  # Shared ephemeral volume for init<->worker
  volume { name = "workspace" }
  container_definitions = jsonencode([
    {
      name      = "init"
      image     = var.init_container_image
      essential = false
      mountPoints = [{ sourceVolume = "workspace", containerPath = "/workspace" }]
      command = ["sh","-lc", local.init_bootstrap_shell]
      environment = concat([
        { name = "AWS_REGION",    value = var.aws_region },
        { name = "BUNDLE_BUCKET", value = var.existing_bucket_name },
        { name = "PROJECT_NAME",  value = var.project_name }
      ], [for k, v in var.extra_environment : { name = k, value = v }])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "init-worker"
        }
      }
    },
    {
      name      = "worker"
      image     = var.locust_container_image
      essential = true
      mountPoints = [{ sourceVolume = "workspace", containerPath = "/workspace" }]
      workingDirectory = "/workspace"
      dependsOn = [{ containerName = "init", condition = "SUCCESS" }]
    # Arguments only; ENTRYPOINT is locust
  command = ["-f","/workspace/locustfile.py","--worker","--master-host","master.${local.namespace_name}","--master-port","5557"]
      environment = concat([
        { name = "LOCUST_MODE", value = "worker" },
        { name = "LOCUST_MASTER_HOST", value = "master.${local.namespace_name}" },
        { name = "PYTHONPATH", value = "/workspace/.deps" }
      ], [for k, v in var.extra_environment : { name = k, value = v }])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
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
    security_groups = [local.ecs_sg_id_resolved]
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
    security_groups = [local.ecs_sg_id_resolved]
    assign_public_ip = true
  }
}
