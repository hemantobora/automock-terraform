# terraform/modules/automock-ecs/ssl.tf
# TLS bifurcation:
#   - custom_domain == "" → self-signed cert (existing behaviour, unchanged)
#   - custom_domain != "" + create_hosted_zone = false → look up existing R53 zone, ACM cert, A-alias
#   - custom_domain != "" + create_hosted_zone = true  → create new R53 zone, ACM cert, A-alias

locals {
  use_custom_domain  = var.custom_domain != ""
  use_self_signed    = !local.use_custom_domain
  byo_hosted_zone    = local.use_custom_domain && !var.create_hosted_zone
  new_hosted_zone    = local.use_custom_domain && var.create_hosted_zone

  # Unified zone_id regardless of whether the zone was looked up or created
  hosted_zone_id = local.new_hosted_zone ? aws_route53_zone.custom[0].zone_id : (
                   local.byo_hosted_zone ? data.aws_route53_zone.custom[0].zone_id : ""
                   )

  # Single reference point for the HTTPS listener cert ARN
  https_cert_arn = local.use_custom_domain ? aws_acm_certificate_validation.custom[0].certificate_arn : aws_acm_certificate.self_signed[0].arn
}

##############################
# PATH A — Self-signed cert
# Active when custom_domain is empty (default)
##############################

resource "tls_private_key" "automock" {
  count     = local.use_self_signed ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "automock" {
  count           = local.use_self_signed ? 1 : 0
  depends_on      = [aws_lb.main]
  private_key_pem = tls_private_key.automock[0].private_key_pem

  subject {
    common_name = aws_lb.main.dns_name
  }

  validity_period_hours = 24 * 365
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self_signed" {
  count            = local.use_self_signed ? 1 : 0
  private_key      = tls_private_key.automock[0].private_key_pem
  certificate_body = tls_self_signed_cert.automock[0].cert_pem

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-selfsigned" })
}

##############################
# PATH B — ACM DNS-validated cert + Route53
# Active when custom_domain is non-empty
##############################

# ── B1: BYO zone ── look up an existing public hosted zone
data "aws_route53_zone" "custom" {
  count        = local.byo_hosted_zone ? 1 : 0
  name         = var.custom_domain
  private_zone = false
}

# ── B2: Create zone ── provision a new public hosted zone
# After apply, delegate NS records at your registrar to activate it.
# force_destroy = true ensures the zone can be cleanly removed on destroy even
# though AWS automatically places SOA + NS records in every new hosted zone
# (those are not Terraform-managed and would otherwise cause HostedZoneNotEmpty).
resource "aws_route53_zone" "custom" {
  count         = local.new_hosted_zone ? 1 : 0
  name          = var.custom_domain
  force_destroy = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-zone" })
}

# Request an ACM certificate for <project_name>.<custom_domain>
resource "aws_acm_certificate" "custom" {
  count             = local.use_custom_domain ? 1 : 0
  domain_name       = "${var.project_name}.${var.custom_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-acm-cert" })
}

# CNAME records ACM needs to prove domain ownership
resource "aws_route53_record" "acm_validation" {
  for_each = local.use_custom_domain ? {
    for dvo in aws_acm_certificate.custom[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id = local.hosted_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}

# Wait for ACM to confirm the cert is issued before the listener references it
resource "aws_acm_certificate_validation" "custom" {
  count                   = local.use_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.custom[0].arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# A-alias record: <project_name>.<custom_domain> → ALB
# Alias records are preferred over CNAMEs for ALBs (no extra DNS query charge
# and health-check aware).
resource "aws_route53_record" "app" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = local.hosted_zone_id
  name    = "${var.project_name}.${var.custom_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

##############################
# ALB Listeners (shared by both paths)
##############################

# HTTP :80 -> forward to TG (port 1080)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api.arn
  }
}

# Private ALB HTTP listener
resource "aws_lb_listener" "http_private" {
  count             = length(aws_lb.private) > 0 ? 1 : 0
  load_balancer_arn = aws_lb.private[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api_private[0].arn
  }
}

# HTTPS :443 -> forward to TG (port 1080)
resource "aws_lb_listener" "https_api" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.https_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api.arn
  }

  depends_on = [
    aws_acm_certificate.self_signed,
    aws_acm_certificate_validation.custom,
  ]
}

# Private ALB HTTPS listener
resource "aws_lb_listener" "https_api_private" {
  count             = length(aws_lb.private) > 0 ? 1 : 0
  load_balancer_arn = aws_lb.private[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.https_cert_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api_private[0].arn
  }

  depends_on = [
    aws_acm_certificate.self_signed,
    aws_acm_certificate_validation.custom,
  ]
}
