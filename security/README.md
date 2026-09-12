# FinLedger — Phase 8: Security

ESO replacing manual secrets, a customer-managed KMS key, the AWS Load Balancer Controller finally standing up the ALB deferred since Phase 4, WAF on that ALB, an IAM audit, and CI security scanning upgrades.

## Two honest scope notes before anything else

**"WAF on the ALB" required building the ALB first.** Phases 4/5 deliberately deferred it — Terraform tagged the subnets, but the ALB itself only gets created dynamically by the AWS Load Balancer Controller from a Kubernetes Ingress. This phase installs that controller and writes the Ingress, closing a loop that's been open since Phase 4.

**"Rate-limit auth endpoints" could not be implemented as literally stated** — there is no login/auth endpoint anywhere in this project; authentication/authorization was never part of any earlier phase. Rather than invent a fake endpoint just to check a box, the WAF's tighter rate limit is applied to the real money-moving endpoint (`/transactions/transfer`), and the gap is named directly in `terraform/waf.tf`'s comments.

## Steps, in dependency order — this one matters more than usual

### 1. Apply the Phase 8 Terraform
```bash
cd phase8-security/terraform
terraform init
terraform apply
```
Note the outputs: `eso_role_arn`, `alb_controller_role_arn`, `waf_web_acl_arn`, `rds_kms_key_arn`.

**Do NOT add `kms_key_id` to the existing Phase 4 `aws_db_instance` resource and re-apply that module expecting an in-place change.** Read `terraform/kms.tf`'s comments — `storage_encrypted`/`kms_key_id` are ForceNew, meaning Terraform would destroy and recreate your database. The file explains the real snapshot-copy-restore migration path for a database with actual data, versus the pragmatic destroy/recreate acceptable for this project's disposable dev data.

### 2. Install the AWS Load Balancer Controller
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  -f helm/alb-controller-values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<alb_controller_role_arn>
```
Runs in `kube-system`, which already has a Fargate profile from Phase 4 (originally for CoreDNS) — nothing new needed there.

### 3. Install External Secrets Operator
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  --namespace finledger \
  -f helm/eso-values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<eso_role_arn>
```

### 4. Apply the SecretStore and ExternalSecret
```bash
kubectl apply -f k8s/cluster-secret-store.yaml
kubectl apply -f k8s/external-secret.yaml
```
Verify:
```bash
kubectl get externalsecret -n finledger
kubectl get secret finledger-db-credentials -n finledger -o yaml
```
The Secret should now show as owned/synced by ESO. **You can now stop worrying about the manual `kubectl create secret` command from Phase 5's README** — this replaces it going forward, and rotating the password in Secrets Manager propagates automatically within 15 minutes.

### 5. Apply the Ingress
Replace `<WAF_WEB_ACL_ARN>` in `k8s/ingress.yaml` with the real value from step 1, then:
```bash
kubectl apply -f k8s/ingress.yaml
kubectl get ingress -n finledger -w
```
Wait for an `ADDRESS` to populate — that's your real, public ALB DNS name. This can take a few minutes.

### 6. Verify the WAF is actually attached
```bash
aws wafv2 get-web-acl-for-resource --resource-arn <alb-arn-from-ingress-status>
```
Should return the WebACL from step 1, not an error.

### 7. Update the CI workflow
Replace `.github/workflows/deploy.yml` with `ci-updates/deploy.yml` — adds the 3 Phase 6 services to the build matrix (a gap from Phase 6's README that's easy to forget to actually do), SARIF upload to the GitHub Security tab, and a separate Terraform misconfiguration scan job.

### 8. Read the IAM audit
`IAM_AUDIT.md` — a role-by-role review of every IAM identity created across all 8 phases, including the two places `Resource: "*"` is the honestly-correct answer rather than a shortcut, and two gaps (no Access Analyzer, no periodic unused-permission review) named rather than hidden.

## What changed vs. what's new

| Requirement | Status |
|---|---|
| ESO + Secrets Manager for DB credentials | New this phase |
| KMS encryption at rest on RDS | New this phase (CMK), with the ForceNew migration reality explained rather than glossed over |
| KMS encryption on DynamoDB | **N/A** — no DynamoDB table exists in this project; it was flagged as optional in the Phase 1 design doc and never built. Noted here rather than silently ignored. |
| WAF on the ALB | New — required building the ALB itself first (see above) |
| Rate-limit transaction endpoints | New — `/transactions/transfer` specifically |
| Rate-limit auth endpoints | **Gap, stated honestly** — no auth endpoint exists |
| IAM least-privilege review | New — `IAM_AUDIT.md` |
| Trivy scanning in CI | **Already existed since Phase 5** — this phase extends it (SARIF, 6-service coverage, Terraform config scanning) rather than adding it from scratch |