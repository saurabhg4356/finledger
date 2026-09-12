# ------------------------------------------------------------------------------
# scope = REGIONAL because this attaches to an ALB, not CloudFront (CloudFront
# WAF ACLs must be scope=CLOUDFRONT and live in us-east-1 regardless of where
# everything else runs — a common mix-up worth naming even though it doesn't
# apply here).
#
# Associated to the ALB via the Ingress annotation
# `alb.ingress.kubernetes.io/wafv2-acl-arn` (see k8s/ingress.yaml) rather than
# a Terraform aws_wafv2_web_acl_association resource — the ALB itself is
# created dynamically by the AWS Load Balancer Controller from a Kubernetes
# Ingress, not by Terraform (see Phase 4's README, "Where's the ALB?"
# section), so Terraform has no ALB ARN to associate against directly.
# ------------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-alb-waf"
  description = "Baseline managed rules + rate limiting for the FinLedger ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # ---- Rule 1: AWS Managed baseline rule set ---------------------------------
  # Covers the common stuff you don't want to hand-roll: SQLi patterns, known
  # bad inputs, oversized bodies, etc. This is the "don't reinvent WAF rules"
  # rule — AWS maintains and updates this rule group's signatures.
  rule {
    name     = "aws-managed-common-rules"
    priority = 1

    override_action {
      none {} # use the managed rule group's own block/count decisions, don't override them
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # ---- Rule 2: general rate limit across the whole ALB -----------------------
  rule {
    name     = "general-rate-limit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5-minute window per source IP
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeneralRateLimit"
      sampled_requests_enabled   = true
    }
  }

  # ---- Rule 3: tighter rate limit specifically on the transfer endpoint ------
  # This is the literal "rate-limit... transaction endpoints" requirement —
  # scoped via a scope-down statement matching the URI path, so this stricter
  # limit only applies to POST /transactions/transfer, not the whole app.
  rule {
    name     = "transaction-endpoint-rate-limit"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100 # much tighter — this is money-moving traffic
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            search_string = "/transactions/transfer"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
            positional_constraint = "STARTS_WITH"
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "TransactionEndpointRateLimit"
      sampled_requests_enabled   = true
    }
  }

  # NOTE — "rate-limit auth endpoints" from the original Phase 2 roadmap could
  # not be implemented as literally stated: no login/auth endpoint exists
  # anywhere in this project. Authentication/authorization was never part of
  # any earlier phase — a real, honest gap, not something to fabricate a fake
  # endpoint for just to check a box. If/when an auth endpoint is added, apply
  # the same scope_down_statement pattern as Rule 3 above, pointed at its path.

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-alb-waf"
    sampled_requests_enabled   = true
  }
}

output "waf_web_acl_arn" { value = aws_wafv2_web_acl.main.arn }