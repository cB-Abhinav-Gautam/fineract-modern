# ---------------------------------------------------------------------------
# TLS certificate for the public listener.
#
# By default the stack issues its own certificate and validates it with DNS
# against the Route 53 zone, so no certificate ARN has to be supplied by hand.
# Set acm_certificate_arn instead if a certificate already exists, for example
# one issued outside this account.
# ---------------------------------------------------------------------------

locals {
  create_certificate = var.acm_certificate_arn == ""

  certificate_arn = local.create_certificate ? module.acm[0].acm_certificate_arn : var.acm_certificate_arn

  # The hostname clients use. Falls back to the load balancer's own DNS name
  # when an external certificate is supplied without a domain.
  service_host = var.domain_name != "" ? var.domain_name : module.alb.dns_name
}

# Fail at plan time with a clear message rather than halfway through an apply.
resource "terraform_data" "certificate_inputs" {
  lifecycle {
    precondition {
      condition     = !local.create_certificate || (var.domain_name != "" && var.route53_zone_name != "")
      error_message = "Set domain_name and route53_zone_name so the stack can issue a certificate, or set acm_certificate_arn to use an existing one."
    }
  }
}

data "aws_route53_zone" "main" {
  count = local.create_certificate ? 1 : 0

  name         = var.route53_zone_name
  private_zone = false
}

module "acm" {
  count = local.create_certificate ? 1 : 0

  source  = "terraform-aws-modules/acm/aws"
  version = "5.1.1"

  domain_name = var.domain_name
  zone_id     = data.aws_route53_zone.main[0].zone_id

  validation_method   = "DNS"
  wait_for_validation = true

  tags = local.common_tags
}

# Point the hostname at the load balancer, so the certificate and the DNS
# record stay consistent with each other.
resource "aws_route53_record" "service" {
  count = local.create_certificate ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.alb.dns_name
    zone_id                = module.alb.zone_id
    evaluate_target_health = true
  }
}
