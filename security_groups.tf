# ---------------------------------------------------------------------------
# Security groups.
#
# Every rule is a reference to another security group rather than a CIDR, with
# one deliberate exception: HTTPS into the load balancer, which defaults to the
# VPC's own CIDR. Nothing egresses to 0.0.0.0/0 - the tasks reach AWS APIs over
# PrivateLink, so there is no need.
#
# No rule anywhere opens port 22 or 3389, as required by the
# no-open-admin-ports policy. There is no SSH path into this stack at all;
# Fargate tasks are reached with ECS Exec over SSM if needed.
#
# The groups consumed by external modules (the load balancer and the database)
# are created with the Apex-approved terraform-aws-modules/security-group
# module. Rules stay as standalone aws_vpc_security_group_*_rule resources so
# that the mutual alb <-> service and service <-> database references cannot
# form a module dependency cycle.
# ---------------------------------------------------------------------------

locals {
  # The load balancer is internal, so callers are inside the VPC by default.
  # Override ingress_cidr_blocks to admit specific peered or on-premises
  # ranges; leaving it empty keeps ingress scoped to this VPC.
  alb_ingress_cidrs = length(var.ingress_cidr_blocks) > 0 ? var.ingress_cidr_blocks : [var.vpc_cidr]
}

# --- Load balancer ---------------------------------------------------------

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.service_prefix}-alb"
  description = "Internal entry point for the accounting service"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(local.alb_ingress_cidrs)

  security_group_id = module.alb_sg.security_group_id
  description       = "HTTPS from permitted clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = module.alb_sg.security_group_id
  description                  = "Forward to the accounting tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.service_port
  to_port                      = var.service_port
  referenced_security_group_id = aws_security_group.service.id

  tags = local.common_tags
}

# --- Accounting tasks ------------------------------------------------------

resource "aws_security_group" "service" {
  name        = "${local.service_prefix}-service"
  description = "Fineract CN accounting tasks on Fargate"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-service" })
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "Application traffic from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = var.service_port
  to_port                      = var.service_port
  referenced_security_group_id = module.alb_sg.security_group_id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "service_to_postgres" {
  security_group_id            = aws_security_group.service.id
  description                  = "PostgreSQL meta database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = module.database_sg.security_group_id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "service_to_mq" {
  security_group_id            = aws_security_group.service.id
  description                  = "OpenWire over TLS to the ActiveMQ broker"
  ip_protocol                  = "tcp"
  from_port                    = 61617
  to_port                      = 61617
  referenced_security_group_id = aws_security_group.mq.id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "service_to_endpoints_https" {
  security_group_id            = aws_security_group.service.id
  description                  = "AWS APIs over PrivateLink"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpc_endpoints.id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "service_to_endpoints_cassandra" {
  security_group_id            = aws_security_group.service.id
  description                  = "CQL over TLS to Amazon Keyspaces"
  ip_protocol                  = "tcp"
  from_port                    = 9142
  to_port                      = 9142
  referenced_security_group_id = aws_security_group.vpc_endpoints.id

  tags = local.common_tags
}

# --- PostgreSQL ------------------------------------------------------------

module "database_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.2.0"

  name        = "${local.service_prefix}-database"
  description = "PostgreSQL instance backing the Fineract CN seshat database"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-database" })
}

resource "aws_vpc_security_group_ingress_rule" "database_from_service" {
  security_group_id            = module.database_sg.security_group_id
  description                  = "PostgreSQL from the accounting tasks"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.service.id

  tags = local.common_tags
}

# --- Amazon MQ -------------------------------------------------------------

resource "aws_security_group" "mq" {
  name        = "${local.service_prefix}-mq"
  description = "ActiveMQ broker for Fineract CN command events"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-mq" })
}

resource "aws_vpc_security_group_ingress_rule" "mq_from_service" {
  security_group_id            = aws_security_group.mq.id
  description                  = "OpenWire over TLS from the accounting tasks"
  ip_protocol                  = "tcp"
  from_port                    = 61617
  to_port                      = 61617
  referenced_security_group_id = aws_security_group.service.id

  tags = local.common_tags
}
