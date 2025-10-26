# terraform/modules/automock-ecs/iam.tf
# IAM Roles and Policies for ECS Tasks (BYO supported for roles only)

# ─────────────────────────────────────────────────────────────
# BYO: Discover existing roles by name from ARN (optional helper)
# ─────────────────────────────────────────────────────────────
data "aws_iam_role" "existing_execution" {
  count = var.use_existing_iam_roles ? 1 : 0
  name  = element(split("/", var.task_execution_role_arn), length(split("/", var.task_execution_role_arn)) - 1)
}

data "aws_iam_role" "existing_task" {
  count = var.use_existing_iam_roles ? 1 : 0
  name  = element(split("/", var.task_role_arn), length(split("/", var.task_role_arn)) - 1)
}

# ─────────────────────────────────────────────────────────────
# Resolved ARNs for wiring into task definition
# ─────────────────────────────────────────────────────────────
locals {
  task_execution_role_arn = var.use_existing_iam_roles ? var.task_execution_role_arn : aws_iam_role.ecs_task_execution[0].arn
  task_role_arn           = var.use_existing_iam_roles ? var.task_role_arn           : aws_iam_role.ecs_task[0].arn
}

# ─────────────────────────────────────────────────────────────
# Create-path (only when NOT using BYO)
# ─────────────────────────────────────────────────────────────

# ECS Task Execution Role (pull images, write logs, etc.)
resource "aws_iam_role" "ecs_task_execution" {
  count = var.use_existing_iam_roles ? 0 : 1

  name_prefix = "${local.name_prefix}-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-execution-role" })
}

# Attach AWS managed execution policy (includes ECR auth + logs)
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  count = var.use_existing_iam_roles ? 0 : 1

  role       = aws_iam_role.ecs_task_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Extra ECR pulls (often redundant, harmless if kept)
resource "aws_iam_role_policy" "ecs_task_execution_ecr" {
  count = var.use_existing_iam_roles ? 0 : 1

  name_prefix = "ecr-access-"
  role        = aws_iam_role.ecs_task_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# ECS Task Role (Your app containers assume this)
resource "aws_iam_role" "ecs_task" {
  count = var.use_existing_iam_roles ? 0 : 1

  name_prefix = "${local.name_prefix}-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-task-role" })
}

# S3 read-only policy for config bucket (MockServer expectations, etc.)
resource "aws_iam_role_policy" "s3_read_config" {
  count = var.use_existing_iam_roles ? 0 : 1

  name_prefix = "s3-config-read-"
  role        = aws_iam_role.ecs_task[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket"
        ]
        Resource = [
          local.config_bucket_arn,
          "${local.config_bucket_arn}/*"
        ]
      }
    ]
  })
}
