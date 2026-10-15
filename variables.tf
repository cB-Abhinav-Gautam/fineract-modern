# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region that hosts the accounting service."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment; becomes the required 'environment' tag."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "The environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Owning team; becomes the required 'owner' tag."
  type        = string
  default     = "platform-engineering"
}

variable "service_name" {
  description = "Short name for the service, used as a resource name prefix."
  type        = string
  default     = "fineract-accounting"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zone_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "Use between 2 and 4 availability zones."
  }
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

variable "service_port" {
  description = "Port the accounting service listens on (server.port in application.yml)."
  type        = number
  default     = 2025
}

variable "service_context_path" {
  description = "Servlet context path the service is published under."
  type        = string
  default     = "/accounting/v1"
}

variable "container_image_tag" {
  description = "Image tag in the ECR repository to deploy."
  type        = string
  default     = "latest"
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 1024
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Number of accounting service tasks to run."
  type        = number
  default     = 2
}

variable "acm_certificate_arn" {
  description = "ARN of an existing ACM certificate for the HTTPS listener. Required: the load balancer terminates TLS and does not serve plain HTTP."
  type        = string
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks permitted to reach the load balancer on HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention for the service and rotation function. At least 365 days, so the logs cover a full audit period."
  type        = number
  default     = 365

  validation {
    condition     = var.log_retention_in_days >= 365
    error_message = "Retain logs for at least 365 days."
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL (the Fineract CN 'seshat' meta database)
# ---------------------------------------------------------------------------

variable "postgres_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "postgres_family" {
  description = "RDS parameter group family matching the engine version."
  type        = string
  default     = "postgres16"
}

variable "postgres_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "postgres_allocated_storage" {
  description = "Initial allocated storage in GiB."
  type        = number
  default     = 50
}

variable "postgres_max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB."
  type        = number
  default     = 250
}

variable "postgres_database_name" {
  description = "Initial database name; Fineract CN expects 'seshat'."
  type        = string
  default     = "seshat"
}

variable "postgres_username" {
  description = "Master username for the PostgreSQL instance."
  type        = string
  default     = "fineract"
}

# ---------------------------------------------------------------------------
# Cassandra (Amazon Keyspaces)
# ---------------------------------------------------------------------------

variable "keyspace_name" {
  description = "Amazon Keyspaces keyspace backing the Fineract CN command store."
  type        = string
  default     = "seshat"
}

# ---------------------------------------------------------------------------
# Amazon MQ (ActiveMQ)
# ---------------------------------------------------------------------------

variable "mq_engine_version" {
  description = "ActiveMQ engine version."
  type        = string
  default     = "5.18.4"
}

variable "mq_host_instance_type" {
  description = "Amazon MQ broker instance type."
  type        = string
  default     = "mq.t3.micro"
}

variable "mq_username" {
  description = "ActiveMQ application username."
  type        = string
  default     = "fineract"
}

variable "mq_secret_rotation_days" {
  description = "How often Secrets Manager rotates the ActiveMQ broker credential, in days."
  type        = number
  default     = 30

  validation {
    condition     = var.mq_secret_rotation_days >= 1 && var.mq_secret_rotation_days <= 365
    error_message = "The rotation interval must be between 1 and 365 days."
  }
}
