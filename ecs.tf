# ---------------------------------------------------------------------------
# ECS Fargate service running the accounting container.
#
# Written as explicit resources rather than through the ECS module: the task
# definition needs precise control over how the PostgreSQL and ActiveMQ
# credentials are injected from Secrets Manager.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "service" {
  name              = "/aws/ecs/${local.service_prefix}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.main.arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/aws/ecs/${local.service_prefix}/exec"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.main.arn

  tags = local.common_tags
}

resource "aws_ecs_cluster" "main" {
  name = local.service_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.main.arn
      logging    = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

locals {
  # Amazon Keyspaces speaks CQL over TLS on 9142.
  keyspaces_contact_point = "cassandra.${var.aws_region}.amazonaws.com:9142"

  container_definition = {
    name      = var.service_name
    image     = "${module.ecr.repository_url}:${var.container_image_tag}"
    essential = true

    portMappings = [
      {
        containerPort = var.service_port
        protocol      = "tcp"
      },
    ]

    # The jar lives in /tmp, so /tmp is a writable ephemeral volume and the
    # rest of the root filesystem is read-only.
    readonlyRootFilesystem = true

    mountPoints = [
      {
        sourceVolume  = "tmp"
        containerPath = "/tmp"
        readOnly      = false
      },
    ]

    environment = [
      { name = "SERVER_PORT", value = tostring(var.service_port) },
      { name = "SERVER_SERVLET_CONTEXT_PATH", value = var.service_context_path },
      { name = "SPRING_CLOUD_DISCOVERY_ENABLED", value = "false" },
      { name = "SPRING_CLOUD_CONFIG_ENABLED", value = "false" },

      { name = "POSTGRESQL_HOST", value = module.postgresql.db_instance_address },
      { name = "POSTGRESQL_PORT", value = "5432" },
      { name = "POSTGRESQL_DATABASE", value = var.postgres_database_name },
      { name = "POSTGRESQL_USER", value = var.postgres_username },

      { name = "CASSANDRA_CONTACTPOINTS", value = local.keyspaces_contact_point },
      { name = "CASSANDRA_KEYSPACE", value = aws_keyspaces_keyspace.main.name },
      { name = "CASSANDRA_CLUSTERNAME", value = local.service_prefix },

      { name = "ACTIVEMQ_BROKERURL", value = aws_mq_broker.fineract.instances[0].endpoints[0] },
      { name = "ACTIVEMQ_USER", value = var.mq_username },
    ]

    secrets = [
      {
        name      = "POSTGRESQL_PASSWORD"
        valueFrom = "${module.postgresql.db_instance_master_user_secret_arn}:password::"
      },
      {
        name      = "ACTIVEMQ_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.mq.arn}:password::"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "accounting"
      }
    }
  }
}

resource "aws_ecs_task_definition" "accounting" {
  family                   = local.service_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([local.container_definition])

  tags = local.common_tags
}

resource "aws_ecs_service" "accounting" {
  name            = local.service_prefix
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.accounting.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = module.alb.target_groups["accounting"].arn
    container_name   = var.service_name
    container_port   = var.service_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Give the Spring Boot application time to run its migrations before the
  # load balancer starts health checking it.
  health_check_grace_period_seconds = 180

  propagate_tags = "SERVICE"
  tags           = local.common_tags

  depends_on = [module.alb]
}
