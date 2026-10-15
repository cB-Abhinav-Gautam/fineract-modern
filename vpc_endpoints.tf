# ---------------------------------------------------------------------------
# PrivateLink endpoints.
#
# Every AWS API the accounting task and the rotation function need is reached
# over a VPC endpoint inside the VPC, so neither needs a route to the public
# internet and the VPC needs no NAT gateway.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.service_prefix}-vpce"
  description = "Interface VPC endpoints used by the accounting service"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from the accounting service tasks"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.service.id

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_cassandra" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "CQL over TLS from the accounting service tasks"
  ip_protocol                  = "tcp"
  from_port                    = 9142
  to_port                      = 9142
  referenced_security_group_id = aws_security_group.service.id

  tags = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_rotation" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from the MQ credential rotation function"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.mq_rotation.id

  tags = local.common_tags
}

# Gateway endpoint for S3, which backs the ECR image layers.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-s3" })
}

# Interface endpoints. Keyspaces listens on 9142, the rest on 443.
locals {
  interface_endpoints = {
    ecr_api        = "ecr.api"
    ecr_dkr        = "ecr.dkr"
    secretsmanager = "secretsmanager"
    kms            = "kms"
    logs           = "logs"
    cassandra      = "cassandra"
    mq             = "mq"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.service_prefix}-${each.key}" })
}
