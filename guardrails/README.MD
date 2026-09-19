## Cost Guardrails

FinLedger's infrastructure is provisioned with cost controls in place **before** any compute, database, or networking resources exist — not bolted on afterward.

### What's in place

1. **Hard monthly budget cap with tiered alerts.** An AWS Budget scoped to `project=finledger` fires SNS notifications at 50%, 80%, and 100% of actual spend, plus a forecasted-100% alert that triggers based on spend trajectory rather than waiting for the money to actually be spent.
2. **Automatic nightly shutdown for stateful resources.** RDS instances tagged `auto_shutdown=true` are stopped every night (EventBridge → Lambda) and restarted each morning. RDS's built-in 7-day auto-restart acts as a safety net if the morning Lambda ever fails to fire.
3. **Least-privilege IAM for the automation itself.** The shutdown/startup Lambda has a role scoped to exactly four RDS actions and CloudWatch Logs — not `AdministratorAccess`, which is the default most tutorials reach for.
4. **Consistent tagging enforced at the provider level.** `default_tags` on the AWS provider means every resource created by this Terraform config is tagged `project`, `managed_by`, and `auto_shutdown` automatically, rather than relying on remembering to tag each resource by hand.
5. **(Optional) Automated hard stop at 100% spend.** A commented-out `aws_budgets_budget_action` resource is included that, when enabled, automatically attaches a deny-new-resources IAM policy at 100% of budget — reversible containment rather than destructive auto-cleanup.

### Why this exists

An earlier project on this account was suspended after an unpaid balance went unnoticed. This isn't a hypothetical control — it's a direct response to that failure, redesigned so the same mistake can't happen silently a second time.

### What it does NOT cover (known trade-offs)

- **NAT Gateways and Application Load Balancers bill hourly regardless of shutdown state** — they can only be stopped by deleting them, which this automation deliberately avoids doing automatically (too destructive for an unattended nightly job). These are the actual biggest fixed costs in this architecture and are best managed by running `terraform destroy` between extended study breaks.
- **ElastiCache has no native stop/start**, unlike RDS — if cost becomes an issue, the trade-off is either accepting the always-on cost or deleting/recreating it via Terraform each session.

### Setup

```bash
cd terraform
terraform init
terraform apply -var="alert_email=you@example.com"
```

Confirm the SNS subscription email before relying on alerts — AWS won't deliver notifications to an unconfirmed subscription.