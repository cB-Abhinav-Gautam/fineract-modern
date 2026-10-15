# ---------------------------------------------------------------------------
# Apache Fineract CN - Accounting service
#
# The repository builds a Spring Boot 2.7 service (Java 21) that listens on
# port 2025 under /accounting/v1 and depends on PostgreSQL, Cassandra and a
# JMS broker. This stack provisions the AWS equivalents.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  service_prefix = "${var.service_name}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  common_tags = {
    owner       = var.owner
    environment = var.environment
    service     = var.service_name
  }
}

# ---------------------------------------------------------------------------
# Customer-managed key.
#
# One key encrypts every data store in the stack: RDS storage and its managed
# master-user secret, Keyspaces tables, the MQ broker, ECR image layers,
# CloudWatch log groups, the rotation function's environment and its dead
# letter queue.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  # Without this the key is unmanageable: it lets IAM policies in this account
  # delegate key use, which is how the task and rotation roles get access.
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CloudWatch Logs uses the key directly, so it needs an explicit grant.
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "Encrypts data at rest for ${local.service_prefix}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = local.common_tags
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.service_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------------------------------------------------------------------
# Network
#
# Private subnets host the tasks, database subnets host PostgreSQL and the MQ
# broker. There is no NAT gateway: every AWS API the tasks use is reached over
# the PrivateLink endpoints in vpc_endpoints.tf.
# ---------------------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.16.0"

  name = local.service_prefix
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets  = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  database_subnets = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, i + 20)]

  create_database_subnet_group = true
  enable_nat_gateway           = false
  enable_dns_hostnames         = true
  enable_dns_support           = true

  # Leave the default security group with no rules at all.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_destination_type                       = "cloud-watch-logs"
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.main.arn
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_in_days

  tags = local.common_tags
}
