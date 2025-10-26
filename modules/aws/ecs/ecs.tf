# terraform/modules/automock-ecs/ecs.tf
# ECS Cluster, Service, Task Definition, and Auto-Scaling

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "mockserver" {
  name              = "/ecs/automock/${var.project_name}/mockserver"
  retention_in_days = 7

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mockserver-logs"
  })
}

resource "aws_cloudwatch_log_group" "config_loader" {
  name              = "/ecs/automock/${var.project_name}/config-loader"
  retention_in_days = 7

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-config-loader-logs"
  })
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cluster"
  })
}

# ECS Cluster Capacity Providers
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "mockserver" {
  family                   = local.name_prefix
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.cpu_units
  memory                   = local.memory_units
  execution_role_arn       = local.task_execution_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([
  # MockServer - NO HEALTH CHECK
  {
    name      = "mockserver"
    image     = "mockserver/mockserver:latest"
    essential = true

    portMappings = [
      {
        containerPort = 1080
        protocol      = "tcp"
        name          = "mockserver-api"
      }
    ]

    environment = [
      {
        name  = "MOCKSERVER_LOG_LEVEL"
        value = "INFO"
      },
      {
        name  = "MOCKSERVER_SERVER_PORT"
        value = "1080"
      },
      {
        name  = "MOCKSERVER_CORS_ALLOW_ORIGIN"
        value = "*"
      },
      {
        name  = "MOCKSERVER_CORS_ALLOW_METHODS"
        value = "GET, POST, PUT, DELETE, PATCH, OPTIONS"
      },
      {
        name = "MOCKSERVER_WATCH_INITIALIZATION_JSON"
        value = "true"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mockserver.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "mockserver"
      }
    }
  },
  
  # Config-Watcher - NON-ESSENTIAL
  {
    name      = "config-watcher"
    # Image that already includes bash + curl + jq + awscli
    image     = "public.ecr.aws/aws-cli/aws-cli:2.17.59"
    essential = false

    dependsOn = [{
      containerName = "mockserver"
      condition     = "START"   # use START since mockserver has no container healthcheck
    }]

    entryPoint = ["/bin/bash", "-c"]

    command = [
      <<-EOF
      #!/usr/bin/env bash
      set -euo pipefail

      # ── Bootstrap tools ────────────────────────────────────────────────────────────
      if ! command -v curl >/dev/null 2>&1; then yum install -y -q curl || dnf install -y -q curl; fi
      if ! command -v jq   >/dev/null 2>&1; then yum install -y -q jq   || dnf install -y -q jq;   fi
      if ! command -v aws  >/dev/null 2>&1; then echo "❌ awscli required"; exit 1; fi

      # ── Env (from task definition) ────────────────────────────────────────────────
      S3_BUCKET="$${S3_BUCKET:-}"
      PROJECT_NAME="$${PROJECT_NAME:-}"
      MOCKSERVER_URL="$${MOCKSERVER_URL:-http://localhost:1080}"
      POLL_INTERVAL="$${POLL_INTERVAL:-30}"
      CONFIG_PATH="$${CONFIG_PATH:-configs/$${PROJECT_NAME}/current.json}"

      export AWS_REGION="$${AWS_REGION:-$${AWS_DEFAULT_REGION:-}}"
      export AWS_DEFAULT_REGION="$${AWS_DEFAULT_REGION:-$${AWS_REGION:-}}"

      echo "🔄 Config Watcher Starting"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "S3 Bucket:      $${S3_BUCKET}"
      echo "Project:        $${PROJECT_NAME}"
      echo "Config Path:    $${CONFIG_PATH}"
      echo "MockServer URL: $${MOCKSERVER_URL}"
      echo "Poll Interval:  $${POLL_INTERVAL}s"
      echo "AWS Region:     $${AWS_REGION:-<not set>}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      if [[ -z "$${S3_BUCKET}" || -z "$${PROJECT_NAME}" ]]; then
        echo "❌ Error: S3_BUCKET and PROJECT_NAME are required"
        exit 1
      fi

      # ── jq filter written to file (no quoting issues, no $! expansion) ────────────
      JQ_FILTER="$(mktemp -t jq_clean.XXXXXX)"
      cat >"$JQ_FILTER" <<'JQ'
      ((.expectations // .) | if type=="array" then . else [] end)
      | map(
        del(.description)
        |
        if ((.httpResponse|type)=="object")
          and ( (.httpResponse.body? // null) | tostring | contains("$!") )
        then
          (
            {
              statusCode: (.httpResponse.statusCode // 200),
              headers:    ((.httpResponse.headers // {}) + {"Content-Type":["application/json"]}),
              body:       (.httpResponse.body)
            }
            + ( if ((.httpResponse.delay|type)=="object") then { delay: .httpResponse.delay } else {} end )
          ) as $tmpl
          |
          .httpResponseTemplate = { templateType:"VELOCITY", template: ($tmpl|tojson) }
          | del(.httpResponse)
        else
          .
        end
      )
      JQ
      echo "🧩 jq filter written to: $JQ_FILTER"

      # ── Helpers ───────────────────────────────────────────────────────────────────
      now() { date "+%Y-%m-%d %H:%M:%S"; }

      validate_file() { # $1 = expectations.json
        local exp_file="$1"
        local payload_file
        payload_file="$(mktemp -t validate.XXXXXX).json"
        jq -nc --slurpfile exp "$exp_file" \
          '{ type:"EXPECTATION", value: ($exp[0] | tostring) }' \
          > "$payload_file"
        curl -s -o /tmp/validate.out -w "%%{http_code}" \
          -X PUT "$${MOCKSERVER_URL}/mockserver/validate" \
          -H "Content-Type: application/json" \
          --data-binary @"$payload_file"
      }

      load_file() { # $1 = expectations.json
        local exp_file="$1"
        curl -s -o /tmp/load.out -w "%%{http_code}" \
          -X PUT "$${MOCKSERVER_URL}/mockserver/expectation" \
          -H "Content-Type: application/json" \
          --data-binary @"$exp_file"
      }

      add_health_check() {
        local http_code
        http_code="$(curl -s -o /tmp/add_health.out -w "%%{http_code}" \
          -X PUT "$${MOCKSERVER_URL}/mockserver/expectation" \
          -H "Content-Type: application/json" \
          -d '[
            {
              "httpRequest": { "method": "GET", "path": "/health" },
              "httpResponse": { "statusCode": 200, "body": "OK" },
              "priority": 0,
              "times": { "unlimited": true }
            }
          ]')"
        echo "❓ /health expectation (HTTP $${http_code})" 
      }


      transform_file() { # in: /tmp/current.json -> out: /tmp/exp.json
        local out
        out="$(mktemp -t expectations.XXXXXX).json"
        jq -c -f "$JQ_FILTER" /tmp/current.json > "$out"
        echo "$out"
      }

      # ── Wait for MockServer ───────────────────────────────────────────────────────
      echo "⏳ Waiting for MockServer to be ready..."
      MAX_WAIT=60; WAITED=0
      while [[ $WAITED -lt $MAX_WAIT ]]; do
        status_code="$(curl -s -o /dev/null -w "%%{http_code}" "$${MOCKSERVER_URL}/" || echo 000)"
        if [[ "$status_code" == "200" || "$status_code" == "404" ]]; then
          echo "✅ MockServer is responding (HTTP $status_code)"
          break
        fi
        echo "   Waiting... $${WAITED}s (got $status_code)"
        sleep 2; WAITED=$((WAITED + 2))
      done
      if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "⚠️  Warning: MockServer not ready after $${MAX_WAIT}s, continuing anyway..."
      fi

      # ── Seed /health (optional) ───────────────────────────────────────────────────
      add_health_check

      LAST_ETAG=""
      UPDATE_COUNT=0
      ERROR_COUNT=0

      # ── Initial load ──────────────────────────────────────────────────────────────
      echo "📥 Loading initial configuration..."
      if aws s3 cp "s3://$${S3_BUCKET}/$${CONFIG_PATH}" /tmp/current.json --only-show-errors 2>/dev/null; then
        jq -e . /tmp/current.json >/dev/null || { echo "❌ raw JSON invalid"; exit 1; }

        EXP_FILE="$(transform_file)"
        jq -e . "$EXP_FILE" >/dev/null || { echo "❌ transformed JSON invalid"; exit 1; }

        EXP_COUNT="$(jq 'length' "$EXP_FILE")"
        echo "🔎 Validating $${EXP_COUNT} expectations..."
        VAL_CODE="$(validate_file "$EXP_FILE")"
        echo "Validate: HTTP $${VAL_CODE}"
        cat /tmp/validate.out || true
        echo

        echo "🧹 Resetting MockServer before loading new expectations..."
        curl -s -X PUT "$${MOCKSERVER_URL}/mockserver/reset" >/dev/null || true

        # ⬇️ ensure /health survives any “replace” semantics
        add_health_check        

        HTTP_CODE="$(load_file "$EXP_FILE")"
        if [[ "$HTTP_CODE" =~ ^20[01]$ ]]; then
          UPDATE_COUNT=$((UPDATE_COUNT + 1))
          echo "✅ Initial expectations loaded (HTTP $HTTP_CODE)"
          LAST_ETAG="$(aws s3api head-object --bucket "$${S3_BUCKET}" --key "$${CONFIG_PATH}" --query 'ETag' --output text 2>/dev/null || echo "")"
        else
          echo "❌ Failed to load initial expectations (HTTP $HTTP_CODE)"
          cat /tmp/load.out || true; echo
          ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
      else
        echo "⚠️  Warning: Could not download initial config from S3"
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi

      echo
      echo "🔄 Starting continuous polling (every $${POLL_INTERVAL}s)..."
      echo "Press Ctrl+C to stop"
      echo

      # ── Poll loop ────────────────────────────────────────────────────────────────
      while true; do
        sleep "$${POLL_INTERVAL}"

        CURRENT_ETAG="$(aws s3api head-object --bucket "$${S3_BUCKET}" --key "$${CONFIG_PATH}" --query 'ETag' --output text 2>/dev/null || echo "")"
        if [[ -z "$${CURRENT_ETAG}" || "$${CURRENT_ETAG}" == "None" ]]; then
          echo "⚠️  [$(now)] Could not fetch ETag from S3"
          ERROR_COUNT=$((ERROR_COUNT + 1))
          continue
        fi

        if [[ "$${CURRENT_ETAG}" == "$${LAST_ETAG}" ]]; then
          echo "✓ [$(now)] No changes detected (ETag: $${CURRENT_ETAG:0:8}...)"
          continue
        fi

        echo "🔔 [$(now)] Change detected! Updating expectations..."
        if ! aws s3 cp "s3://$${S3_BUCKET}/$${CONFIG_PATH}" /tmp/current.json --only-show-errors 2>/dev/null; then
          echo "❌ [$(now)] Failed to download config"
          ERROR_COUNT=$((ERROR_COUNT + 1))
          continue
        fi

        if ! jq -e . /tmp/current.json >/dev/null; then
          echo "❌ [$(now)] Raw JSON invalid"
          ERROR_COUNT=$((ERROR_COUNT + 1))
          continue
        fi

        EXP_FILE="$(transform_file)"
        if ! jq -e . "$EXP_FILE" >/dev/null; then
          echo "❌ [$(now)] Transformed JSON invalid"
          ERROR_COUNT=$((ERROR_COUNT + 1))
          continue
        fi

        EXP_COUNT="$(jq 'length' "$EXP_FILE")"
        echo "🔎 Validating $${EXP_COUNT} expectations..."
        VAL_CODE="$(validate_file "$EXP_FILE")"
        echo "Validate: HTTP $${VAL_CODE}"
        cat /tmp/validate.out || true
        echo

        echo "🧹 Resetting MockServer before loading new expectations..."
        curl -s -X PUT "$${MOCKSERVER_URL}/mockserver/reset" >/dev/null || true

        # ⬇️ ensure /health survives any “replace” semantics
        add_health_check

        HTTP_CODE="$(load_file "$EXP_FILE")"
        if [[ "$HTTP_CODE" =~ ^20[01]$ ]]; then
          UPDATE_COUNT=$((UPDATE_COUNT + 1))
          LAST_ETAG="$${CURRENT_ETAG}"
          echo "✅ [$$(now)] Updated $${EXP_COUNT} expectations (HTTP $${HTTP_CODE})"
          echo "   Total updates: $${UPDATE_COUNT}, Errors: $${ERROR_COUNT}"
        else
          ERROR_COUNT=$((ERROR_COUNT + 1))
          echo "❌ [$$(now)] Failed to update MockServer (HTTP $${HTTP_CODE})"
          cat /tmp/load.out || true; echo
        fi
      done
      EOF
    ]

    environment = [
      { name = "AWS_REGION",         value = var.region },
      { name = "AWS_DEFAULT_REGION", value = var.region },
      { name = "S3_BUCKET",          value = local.s3_config.bucket_name },
      { name = "PROJECT_NAME",       value = var.project_name },
      { name = "MOCKSERVER_URL",     value = "http://localhost:1080" },
      { name = "POLL_INTERVAL",      value = "30" }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.config_loader.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "config-watcher"
      }
    }
  }
])

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-task"
  })
}

# ECS Service
resource "aws_ecs_service" "mockserver" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.mockserver.arn
  desired_count   = var.min_tasks
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.private_subnet_ids_resolved          # CHANGED
    security_groups  = local.ecs_security_group_ids_resolved      # CHANGED
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mockserver_api.arn
    container_name   = "mockserver"
    container_port   = 1080
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-service"
  })

  depends_on = [
    aws_lb_listener.https_api
  ]
}

# Auto-Scaling Target
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = var.max_tasks
  min_capacity       = var.min_tasks
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.mockserver.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# CPU-Based Step Scaling Policy
resource "aws_appautoscaling_policy" "cpu_step_scaling" {
  name               = "${local.name_prefix}-cpu-step-scaling"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "PercentChangeInCapacity"
    cooldown               = 60
    metric_aggregation_type = "Average"

    # 70-80% CPU: Add 50% more tasks
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 10
      scaling_adjustment          = 50
    }

    # 80-90% CPU: Add 100% more tasks
    step_adjustment {
      metric_interval_lower_bound = 10
      metric_interval_upper_bound = 20
      scaling_adjustment          = 100
    }

    # 90%+ CPU: Add 200% more tasks
    step_adjustment {
      metric_interval_lower_bound = 20
      scaling_adjustment          = 200
    }
  }
}

# CPU High Alarm
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name_prefix}-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "70"
  alarm_description   = "Triggers step scaling when CPU >= 70%"
  alarm_actions       = [aws_appautoscaling_policy.cpu_step_scaling.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.mockserver.name
  }

  tags = local.common_tags
}

# Memory-Based Step Scaling Policy
resource "aws_appautoscaling_policy" "memory_step_scaling" {
  name               = "${local.name_prefix}-memory-step-scaling"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "PercentChangeInCapacity"
    cooldown               = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 10
      scaling_adjustment          = 50
    }

    step_adjustment {
      metric_interval_lower_bound = 10
      metric_interval_upper_bound = 20
      scaling_adjustment          = 100
    }

    step_adjustment {
      metric_interval_lower_bound = 20
      scaling_adjustment          = 200
    }
  }
}

# Memory High Alarm
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${local.name_prefix}-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "70"
  alarm_description   = "Triggers step scaling when memory >= 70%"
  alarm_actions       = [aws_appautoscaling_policy.memory_step_scaling.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.mockserver.name
  }

  tags = local.common_tags
}

# Request Count Step Scaling Policy
resource "aws_appautoscaling_policy" "request_step_scaling" {
  name               = "${local.name_prefix}-request-step-scaling"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type         = "PercentChangeInCapacity"
    cooldown               = 60
    metric_aggregation_type = "Average"

    # 500-1000 req/min per task: Add 50%
    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 500
      scaling_adjustment          = 50
    }

    # 1000+ req/min per task: Add 100%
    step_adjustment {
      metric_interval_lower_bound = 500
      scaling_adjustment          = 100
    }
  }
}

# Request Count High Alarm
resource "aws_cloudwatch_metric_alarm" "requests_high" {
  alarm_name          = "${local.name_prefix}-requests-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "500"
  alarm_description   = "Triggers step scaling when requests >= 500/min per target"
  alarm_actions       = [aws_appautoscaling_policy.request_step_scaling.arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.mockserver_api.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  tags = local.common_tags
}

# Scale Down Policy
resource "aws_appautoscaling_policy" "scale_down" {
  name               = "${local.name_prefix}-scale-down"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type         = "PercentChangeInCapacity"
    cooldown               = 300 # 5 min cooldown
    metric_aggregation_type = "Average"

    # Remove 25% of tasks when low
    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -25
    }
  }
}

# CPU Low Alarm
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${local.name_prefix}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "40"
  alarm_description   = "Scale down when CPU < 40% for 5 minutes"
  alarm_actions       = [aws_appautoscaling_policy.scale_down.arn]

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.mockserver.name
  }

  tags = local.common_tags
}
