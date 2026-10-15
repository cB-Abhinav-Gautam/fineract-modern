# ---------------------------------------------------------------------------
# Internal entry point.
#
# The accounting service is an internal Fineract CN microservice: it is called
# by other services in the mesh, not by the public internet. The load balancer
# is therefore internal and sits in the private subnets, with no public
# address.
#
# TLS terminates at the load balancer; there is no plain-HTTP listener. The
# health check targets the service context path, which is what the Spring Boot
# application serves under /accounting/v1.
# ---------------------------------------------------------------------------

# Access log bucket. ALB log delivery writes with SSE-S3, so this bucket uses
# AES256 rather than the customer-managed key.
module "alb_logs" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.2.2"

  bucket_prefix = "${local.service_prefix}-alb-logs-"

  force_destroy            = false
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_elb_log_delivery_policy        = true
  attach_lb_log_delivery_policy         = true
  attach_deny_insecure_transport_policy = true

  versioning = {
    status = "Enabled"
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id     = "expire-old-logs"
      status = "Enabled"

      filter = {
        prefix = ""
      }

      noncurrent_version_expiration = {
        noncurrent_days = 30
      }

      expiration = {
        days = 365
      }
    },
  ]

  tags = local.common_tags
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.12.0"

  name    = local.service_prefix
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # Reachable only from inside the VPC and anything routed into it. A core
  # banking ledger has no reason to be exposed to the internet.
  internal = true

  # Use the security group defined in security_groups.tf rather than letting
  # the module create one.
  create_security_group = false
  security_groups       = [module.alb_sg.security_group_id]

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  access_logs = {
    bucket  = module.alb_logs.s3_bucket_id
    prefix  = "alb"
    enabled = true
  }

  listeners = {
    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      certificate_arn = local.certificate_arn

      forward = {
        target_group_key = "accounting"
      }
    }
  }

  target_groups = {
    accounting = {
      name_prefix = "acct-"
      protocol    = "HTTP"
      port        = var.service_port
      target_type = "ip"

      # ECS registers and deregisters the targets.
      create_attachment = false

      deregistration_delay = 30

      health_check = {
        enabled             = true
        path                = var.service_context_path
        port                = "traffic-port"
        protocol            = "HTTP"
        matcher             = "200-399"
        interval            = 30
        timeout             = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
      }
    }
  }

  tags = local.common_tags
}
