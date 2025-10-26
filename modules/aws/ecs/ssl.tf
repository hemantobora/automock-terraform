# terraform/modules/automock-ecs/ssl.tf
# TLS via terraform tls -> import to ACM -> ALB listeners (80->443, 443->TG 1080)

##############################
# TLS (self-signed) -> ACM
##############################

# Private key for self-signed cert
resource "tls_private_key" "automock" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Self-signed cert: CN = ALB DNS name (ensures ALB exists first)
resource "tls_self_signed_cert" "automock" {
  depends_on       = [aws_lb.main]                 # be explicit (also implied by reference)
  private_key_pem  = tls_private_key.automock.private_key_pem

  subject {
    common_name = aws_lb.main.dns_name             # e.g., *.elb.amazonaws.com
  }

  validity_period_hours = 24 * 365                 # 1 year
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Import the self-signed cert into ACM so ALB can use it
resource "aws_acm_certificate" "automock" {
  private_key      = tls_private_key.automock.private_key_pem
  certificate_body = tls_self_signed_cert.automock.cert_pem

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-selfsigned" })
}

##############################
# ALB Listeners
##############################

# Always redirect HTTP :80 -> HTTPS :443
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api.arn
  }
}

# HTTPS :443 -> forward to TG (port 1080)
resource "aws_lb_listener" "https_api" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.automock.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mockserver_api.arn
  }
}
