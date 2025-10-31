# automock-terraform

Terraform modules to deploy AutoMock infrastructure on AWS. This repository provides:

- aws/state-backend: An S3 bucket + DynamoDB table for Terraform remote state and locking.
- aws/ecs: A production-ready ECS Fargate stack fronted by an ALB for running AutoMock at scale.

Status and scope

- Cloud provider: AWS only
- Cost note: These modules create paid resources (ALB, NAT Gateway, ECS tasks, CloudWatch, S3). Always review your plan and set budgets/alerts. For load testing, ECS tasks and ALB/NAT costs can add up quickly.

Prerequisites

- Terraform >= 1.0
- AWS account and credentials configured (ENV, ~/.aws, or SSO)
- Optional but recommended: a dedicated AWS account or project for load testing

Quick start

1) Create a shared remote state backend (once per region)

Create a folder (e.g. infra/state) and use the state-backend module:

```hcl
terraform {
	required_version = ">= 1.0"
	required_providers {
		aws = {
			source  = "hashicorp/aws"
			version = "~> 5.0"
		}
	}
}

provider "aws" {
	region = var.region
}

module "state_backend" {
	source = "../modules/aws/state-backend"
	region = var.region
	tags   = { Project = "AutoMock" }
}

output "backend_config" { value = module.state_backend.backend_config }
```

Apply, then configure your projects to use the S3 backend using the values from the outputs:

```hcl
terraform {
	backend "s3" {
		bucket         = "<state_bucket_name>"
		region         = "<region>"
		encrypt        = true
		dynamodb_table = "<lock_table_name>"
		key            = "automock/ecs/terraform.tfstate"
	}
}
```

2) Deploy AutoMock on ECS Fargate

Create another folder (e.g. infra/ecs) and wire up the ECS module. Minimal example (creates networking unless BYO is enabled):

```hcl
terraform {
	required_version = ">= 1.0"
	required_providers {
		aws = {
			source  = "hashicorp/aws"
			version = "~> 5.0"
		}
	}

	# Use the backend you created above
	backend "s3" {
		bucket         = "<state_bucket_name>"
		region         = "<region>"
		encrypt        = true
		dynamodb_table = "<lock_table_name>"
		key            = "automock/ecs/terraform.tfstate"
	}
}

provider "aws" {
	region = var.region
}

module "automock_ecs" {
	source       = "../modules/aws/ecs"
	project_name = var.project_name
	region       = var.region

	# Size and scale
	instance_size = "small"   # small | medium | large | xlarge
	min_tasks     = 10         # for load testing, start higher
	max_tasks     = 200

	# Optional: reference an existing S3 bucket where AutoMock reads config
	# Either provide this object…
	# s3_bucket_configuration = {
	#   bucket_name     = "my-automock-config"
	#   metadata_path   = "project-metadata.json"
	#   versions_prefix = "versions/"
	# }
	# …or pass just the name/arn
	# config_bucket_name = "my-automock-config"
	# config_bucket_arn  = "arn:aws:s3:::my-automock-config"

	tags = { Environment = "dev" }
}

output "endpoints" {
	value = {
		api       = module.automock_ecs.mockserver_url
		dashboard = module.automock_ecs.dashboard_url
	}
}
```

Then:

```sh
terraform init
terraform plan
terraform apply
```

You’ll get a HTTPS endpoint for the MockServer API and dashboard.

Module: aws/state-backend

Creates a hardened, versioned S3 bucket and a DynamoDB table for Terraform state.

Inputs

- region (string): AWS region. If omitted, uses the current provider region.
- tags (map(string)): Optional tags.

Outputs

- state_bucket_name, state_bucket_arn
- lock_table_name, lock_table_arn
- region
- backend_config: convenience map with bucket/region/encrypt/dynamodb_table

Module: aws/ecs

Provisions the network and compute for AutoMock:

- VPC, subnets (2 public, 2 private), route tables, and a single cost-optimized NAT Gateway (unless BYO)
- Security groups for ALB and ECS tasks
- Application Load Balancer + target group; HTTP/HTTPS listeners and health checks
- ECS Cluster, Task Definition, and Service (Fargate)
- CloudWatch log group for the service
- S3 configuration wiring for AutoMock (reads expectations/metadata from a bucket you provide)

Key inputs

- project_name (string, required): Lowercase letters, numbers, hyphens only
- region (string): AWS region (default us-east-1)
- instance_size (string): small | medium | large | xlarge (default small)
- min_tasks (number): Minimum ECS tasks (default 10)
- max_tasks (number): Maximum ECS tasks (default 200)
- cpu_units (number): Task CPU units (default 256)
- memory_units (number): Task memory MiB (default 512)
- s3_bucket_configuration (object|null): { bucket_name, metadata_path, versions_prefix }
- config_bucket_name/config_bucket_arn (string): Alternative way to point at your existing bucket

BYO toggles (advanced)

- use_existing_vpc (bool) + vpc_id
- use_existing_subnets (bool) + public_subnet_ids + private_subnet_ids
- use_existing_security_groups (bool) + security_group_ids (index 0 = ALB, index 1 = ECS)
- use_existing_igw (bool) + internet_gateway_id
- use_existing_nat (bool) + nat_gateway_ids
- use_existing_iam_roles (bool) + task_execution_role_arn + task_role_arn

Notes on S3 configuration

- This module does not create your configuration bucket; it only wires the task to read from it. Create the S3 bucket separately or reuse an existing one.
- If you don’t pass s3_bucket_configuration or config_bucket_name, the module will resolve a reasonable name internally for wiring, but you still need an actual bucket created outside this module.

Outputs

- alb_dns_name, alb_zone_id
- cluster_name, cluster_arn
- service_name, service_arn
- task_definition_arn
- vpc_id, public_subnet_ids, private_subnet_ids
- alb_security_group_id, ecs_security_group_id
- config_bucket
- mockserver_url, dashboard_url
- infrastructure_summary: friendly JSON-style map of the deployment
- cli_integration_commands: helpful curl/AWS CLI commands

BYO examples

1) Use existing networking and security groups

```hcl
module "automock_ecs" {
	source       = "../modules/aws/ecs"
	project_name = var.project_name
	region       = var.region

	use_existing_vpc             = true
	vpc_id                       = "vpc-1234567890"
	use_existing_subnets         = true
	public_subnet_ids            = ["subnet-a", "subnet-b"]
	private_subnet_ids           = ["subnet-c", "subnet-d"]
	use_existing_security_groups = true
	security_group_ids           = ["sg-alb", "sg-ecs"]
}
```

2) Use existing IAM roles

```hcl
module "automock_ecs" {
	source       = "../modules/aws/ecs"
	project_name = var.project_name
	region       = var.region

	use_existing_iam_roles  = true
	task_execution_role_arn = "arn:aws:iam::123456789012:role/ecsTaskExecutionRole"
	task_role_arn           = "arn:aws:iam::123456789012:role/automockTaskRole"
}
```

Operations

- Health: curl https://<alb>/health
- List expectations: curl https://<alb>/mockserver/expectation
- Reset expectations: curl -X PUT https://<alb>/mockserver/reset
- Scale service: aws ecs update-service --cluster <name> --service <name> --desired-count <N>
- View logs: aws logs tail /ecs/automock/<project>/mockserver --follow

Cost and cleanup

- ALB and NAT Gateways incur hourly charges. ECS tasks incur per-vCPU/GB-hour charges. CloudWatch and S3 incur usage-based charges.
- For ephemeral testing, consider:
	- Lowering min_tasks and scaling up only during tests
	- Disabling NAT with BYO public subnets (if your tasks can run publicly)
	- Tearing down stacks when idle: terraform destroy

Troubleshooting

- 403/404 from the dashboard: ensure target group health checks are passing and security groups allow ALB->ECS on port 1080.
- No expectations loaded: verify your S3 bucket and object paths match what AutoMock expects (metadata_path, versions_prefix).
- Slow startup: large task counts and certificate validation can add a few minutes; check CloudWatch logs for progress.

License

MIT License, see LICENSE in the parent project.
