# FinLedger — Phase 6: Async Decoupling

SNS fan-out → two SQS queues (fraud, notification), each with its own DLQ. The outbox-poller activates the `outbox_events` table that's existed since Phase 1 but had nothing reading it until now.

## Required updates to earlier phases first

Being upfront about this rather than letting you discover it via a confusing failure:

**1. Phase 4's ECR module needs 3 more repos.** `modules/ecr/main.tf`'s `service_names` variable currently only lists the original three services. Update the default to:
```hcl
variable "service_names" {
  type    = list(string)
  default = [
    "account-service", "ledger-service", "transaction-service",
    "outbox-poller", "fraud-service", "notification-service"
  ]
}
```
Re-run `terraform apply` in `phase4-infrastructure/terraform` with this change before building any Phase 6 images.

**2. Phase 5's CI role policy needs those same 3 repos added** to the `ECRPushPull` statement's `resources` list in `phase5-cicd/terraform/oidc.tf`, and the GitHub Actions workflow's `matrix.service` list needs the 3 new service names added, each with its own `containerPort` handled correctly (`outbox-poller` doesn't listen on a service port the same way — see its manifest). Re-apply Phase 5's Terraform after this change.

This is a normal part of how an infra repo evolves — each new phase touches something that already exists, not just new files. Worth documenting exactly like this in your own repo's changelog/commits, since "what did I have to go back and change" is itself a good interview answer to "how do you manage infrastructure evolving over time."

## Steps

### 1. Apply the messaging + IRSA Terraform
```bash
cd phase6-async/terraform
terraform init
terraform apply
```
Note the outputs: `sns_topic_arn`, `fraud_queue_url`, `fraud_dlq_url`, `notification_queue_url`, `notification_dlq_url`.

### 2. Run the DB migration
```bash
psql "postgresql://finledger_admin:<password>@<rds-endpoint>:5432/finledger" -f db/006_phase6_async.sql
```

### 3. Update the earlier phases (see above), re-apply their Terraform

### 4. Build and push the 3 new images
Same pattern as Phase 4/5 — build, tag with a real version, push to the newly created ECR repos. If you've already wired the CI workflow's matrix to include these services, a push to `main` handles this automatically going forward.

### 5. Apply the Kubernetes manifests
Replace every `<ACCOUNT_ID>`, `<SNS_TOPIC_ARN_FROM_TERRAFORM_OUTPUT>`, `<FRAUD_QUEUE_URL_FROM_TERRAFORM_OUTPUT>`, and `<NOTIFICATION_QUEUE_URL_FROM_TERRAFORM_OUTPUT>` placeholder in `k8s/async-services.yaml` with the real values from step 1's Terraform output, then:
```bash
kubectl apply -f k8s/async-services.yaml
```

### 6. Verify a real transfer flows all the way through
```bash
# make a transfer via transaction-service, then within a few seconds:
kubectl logs -n finledger deployment/outbox-poller --tail=20
kubectl logs -n finledger deployment/fraud-service --tail=20
kubectl logs -n finledger deployment/notification-service --tail=20
```
You should see the poller publish the event, and both consumers independently pick it up — this is the fan-out actually working, not just configured.

### 7. Run the poison-message test
```bash
export FRAUD_QUEUE_URL=<from terraform output>
export FRAUD_DLQ_URL=<from terraform output>
pip install -r tests/requirements-test.txt
pytest tests/test_poison_message.py -v -s
```
This test is slow (~2–3 minutes) by design — proving DLQ arrival honestly means waiting through real SQS retries and visibility timeouts, not mocking the wait away.

## Why IRSA instead of AWS keys in a Secret

Every new service here calls AWS APIs directly (SNS publish, SQS receive/delete) — the first time in this project that's been necessary. The tempting shortcut is an `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` pair baked into a Kubernetes Secret. IRSA avoids that entirely: each pod assumes a real, short-lived, auto-rotated IAM role scoped to exactly the one queue or topic it needs, with zero long-lived credentials existing anywhere. This is worth walking an interviewer through explicitly if asked "how do your pods authenticate to AWS" — it's a meaningfully better answer than "there's a Secret with keys in it."

## Known limitations at this stage

- **`outbox-poller` runs as a single replica.** The `FOR UPDATE SKIP LOCKED` query makes scaling to more replicas safe whenever needed, but one replica is enough at this traffic level — no reason to pay for more yet.
- **Fraud scoring is a placeholder rule** (flag above a fixed rupee threshold), not real fraud detection. That's intentional — the async/reliability pattern is what this phase is actually demonstrating.
- **No alerting on DLQ arrivals yet.** A message quietly sitting in the DLQ with nobody watching isn't much better than losing it. A CloudWatch alarm on `ApproximateNumberOfMessagesVisible` for both DLQs, wired to the same SNS-based alerting you'll build in Phase 7's observability work, is the natural next step — worth doing before calling this phase "production-ready" even for a portfolio project.