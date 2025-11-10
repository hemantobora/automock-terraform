# Locust on AWS (Terraform Module)

A minimal Terraform module that deploys a Locust cluster on AWS using ECS Fargate and an Application Load Balancer. It provisions:

- VPC with two public subnets
- Security groups for ALB and ECS tasks
- Public ALB with HTTP and HTTPS (self-signed cert imported into ACM)
- ECS cluster
- Cloud Map private DNS namespace and a `master` service
- CloudWatch log group (configurable retention)
- ECS task definitions and services for Locust master and workers

> Note: The HTTPS listener uses a self-signed certificate via the `tls` provider and imports it into ACM. Replace with a real ACM certificate for production.

## Usage

Local module (this repository structure):

```hcl
module "aws_locust" {
  source = "./modules/locust-aws"

  project_name           = var.project_name
  aws_region             = var.aws_region
  cpu_units              = var.cpu_units
  memory_units           = var.memory_units
  worker_desired_count   = var.worker_desired_count
  master_port            = var.master_port
  log_retention_days     = var.log_retention_days
  locust_container_image = var.locust_container_image
}
```

After publishing to a separate repository, you can consume it like:

```hcl
module "aws_locust" {
  source  = "github.com/your-org/terraform-aws-locust?ref=v0.1.0"
  # ...same inputs
}
```

## Inputs

- `project_name` (string, required): Project identifier used for names.
- `aws_region` (string, required): AWS region for resources/logs.
- `cpu_units` (number, required): Fargate CPU units for tasks (e.g., 256, 512, 1024).
- `memory_units` (number, required): Fargate memory in MiB (e.g., 512, 1024, 2048).
- `worker_desired_count` (number, required): Initial desired worker count for the worker service.
- `master_port` (number, required): Locust master UI/container port (default 8089 typically).
- `log_retention_days` (number, required): CloudWatch logs retention in days.
- `locust_container_image` (string, required): Container image URI for Locust master/worker.

## Outputs

- `alb_dns_name`: Public ALB DNS name where Locust UI is reachable.
- `alb_https_listener_arn`: ARN of the HTTPS listener.
- `cluster_name`: ECS cluster name.
- `namespace_name`: Cloud Map private namespace name.
- `master_service_name`: ECS service name for Locust master.
- `worker_service_name`: ECS service name for Locust workers.
- `security_group_ecs_id`: Security group ID attached to ECS tasks.
- `vpc_id`: The VPC ID.
- `subnet_ids`: The public subnet IDs.
- `cloud_map_master_fqdn`: FQDN for Locust master inside the private namespace (e.g., `master.project.local`).

## Notes

- Scaling workers should be done by updating `worker_desired_count` and re-applying Terraform to avoid configuration drift with ECS.
- Replace the self-signed TLS certificate with a valid ACM certificate and DNS for production workloads.
- The module currently places tasks in public subnets with public IPs for simplicity. You can adapt it for private subnets with NAT.
