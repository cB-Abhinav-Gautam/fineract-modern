# ---------------------------------------------------------------------------
# Security groups.
#
# Every rule is a reference to another security group rather than a CIDR, with
# one deliberate exception: HTTPS into the load balancer. Nothing egresses to
# 0.0.0.0/0 - the tasks reach AWS APIs over PrivateLink, so there is no need.
#
# No rule anywhere opens port 22 or 3389, as required by the
# no-open-admin-ports policy. There is no SSH path into this stack at all;
# Fargate tasks are reached with ECS Exec over SSM if needed.
# ---------------------------------------------------------------------------

# --- Load balancer ---------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.service_prefix}-alb"
  description = "Public entry point for the accounting service"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.ingress_cidr_blocks)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from permitted clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
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
  referenced_security_group_id = aws_security_group.alb.id

  tags = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "service_to_postgres" {
  security_group_id            = aws_security_group.service.id
  description                  = "PostgreSQL meta database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.database.id

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

resource "aws_security_group" "database" {
  name        = "${local.service_prefix}-database"
  description = "PostgreSQL instance backing the Fineract CN seshat database"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-database" })
}

resource "aws_vpc_security_group_ingress_rule" "database_from_service" {
  security_group_id            = aws_security_group.database.id
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
