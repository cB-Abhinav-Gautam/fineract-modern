# ---------------------------------------------------------------------------
# PostgreSQL: the Fineract CN 'seshat' meta database (tenant registry).
# Encrypted at rest with the customer-managed key, private, multi-AZ.
# ---------------------------------------------------------------------------

module "postgresql" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.10.0"

  identifier = "${local.service_prefix}-postgres"

  engine                     = "postgres"
  engine_version             = var.postgres_engine_version
  family                     = var.postgres_family
  major_engine_version       = split(".", var.postgres_engine_version)[0]
  instance_class             = var.postgres_instance_class
  auto_minor_version_upgrade = true

  allocated_storage     = var.postgres_allocated_storage
  max_allocated_storage = var.postgres_max_allocated_storage
  storage_type          = "gp3"

  # Mandatory policy: encryption at rest.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  db_name  = var.postgres_database_name
  username = var.postgres_username
  port     = 5432

  # No password in code or state: RDS generates it and Secrets Manager
  # rotates it under AWS-managed rotation.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  iam_database_authentication_enabled = true

  multi_az               = true
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  backup_retention_period          = 14
  backup_window                    = "02:00-03:00"
  maintenance_window               = "Mon:03:00-Mon:04:00"
  copy_tags_to_snapshot            = true
  deletion_protection              = true
  skip_final_snapshot              = false
  final_snapshot_identifier_prefix = "${local.service_prefix}-final"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.main.arn
  performance_insights_retention_period = 7

  create_monitoring_role = true
  monitoring_interval    = 60
  monitoring_role_name   = "${local.service_prefix}-rds-monitoring"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  parameters = [
    {
      name  = "rds.force_ssl"
      value = "1"
    },
    {
      name  = "log_min_duration_statement"
      value = "1000"
    },
  ]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Cassandra: Amazon Keyspaces provides the managed CQL API that the
# fineract-cn 'cassandra' library talks to. Tables are created by the
# service's own migration logic at first start, so only the keyspace is
# declared here.
# ---------------------------------------------------------------------------

resource "aws_keyspaces_keyspace" "main" {
  name = var.keyspace_name

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Amazon MQ (ActiveMQ): the JMS broker Fineract CN uses to publish command
# events between services.
# ---------------------------------------------------------------------------

resource "random_password" "mq" {
  length = 32

  # Amazon MQ rejects commas, colons and equals signs in ActiveMQ passwords.
  override_special = "._~-"
  special          = true
}

resource "aws_secretsmanager_secret" "mq" {
  name        = "${local.service_prefix}/mq/app-credential"
  description = "ActiveMQ application credential for ${local.service_prefix}"
  kms_key_id  = aws_kms_key.main.arn

  recovery_window_in_days = 30

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "mq" {
  secret_id = aws_secretsmanager_secret.mq.id

  secret_string = jsonencode({
    username = var.mq_username
    password = random_password.mq.result
  })

  lifecycle {
    # After the first apply the rotation function owns this value.
    ignore_changes = [secret_string]
  }
}

resource "aws_mq_broker" "fineract" {
  broker_name = "${local.service_prefix}-activemq"

  engine_type                = "ActiveMQ"
  engine_version             = var.mq_engine_version
  host_instance_type         = var.mq_host_instance_type
  deployment_mode            = "ACTIVE_STANDBY_MULTI_AZ"
  auto_minor_version_upgrade = true
  publicly_accessible        = false

  subnet_ids      = slice(module.vpc.database_subnets, 0, 2)
  security_groups = [aws_security_group.mq.id]

  encryption_options {
    kms_key_id        = aws_kms_key.main.arn
    use_aws_owned_key = false
  }

  logs {
    general = true
    audit   = true
  }

  maintenance_window_start_time {
    day_of_week = "Monday"
    time_of_day = "03:00"
    time_zone   = "UTC"
  }

  user {
    username = var.mq_username
    password = random_password.mq.result
  }

  lifecycle {
    # The rotation function changes this password on a schedule; Terraform
    # must not revert it on the next apply.
    ignore_changes = [user]
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# ECR: registry for the accounting service image built from the repository
# Dockerfile (amazoncorretto:21-alpine, bootable Spring Boot jar).
# ---------------------------------------------------------------------------

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "2.3.1"

  repository_name = local.service_prefix

  repository_image_tag_mutability = "IMMUTABLE"
  repository_image_scan_on_push   = true
  repository_encryption_type      = "KMS"
  repository_kms_key              = aws_kms_key.main.arn
  repository_force_delete         = false

  create_lifecycle_policy = true
  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      },
    ]
  })

  tags = local.common_tags
}
