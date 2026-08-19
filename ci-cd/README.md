# FinLedger — Phase 5: CI/CD

GitHub Actions with OIDC (no long-lived AWS keys stored in GitHub) → Trivy scan → push to ECR → `kubectl set image` deploy to EKS.

## Before you start — one required change to Phase 4

EKS Access Entries (used below to grant the CI role kubectl permissions) require the cluster's authentication mode to include `API`. If your Phase 4 cluster doesn't already have this, add it to `modules/eks/main.tf` inside the `aws_eks_cluster` resource:

```hcl
resource "aws_eks_cluster" "main" {
  # ...existing config...

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions  = true
  }
}
```

Run `terraform apply` on Phase 4 with this change **before** applying Phase 5's Terraform, or the access entry resources below will fail.

## A note on GitHub's OIDC rollout — check this before debugging anything else

GitHub changed the default OIDC subject-claim format for **repositories created after July 15, 2026**, adding immutable owner/repo IDs. Since `finledger` may be new enough to be affected, the trust policy in `oidc.tf` uses a wildcard pattern that matches both the old and new formats — this is intentional, not a mistake if you see `saurabhg4356*` instead of a plain name in the trust policy. If the workflow ever fails with `not authorized to perform: sts:AssumeRoleWithWebIdentity` and everything else looks right, this is the first thing to check — compare the actual `sub` claim in the workflow's OIDC token debug output against what the trust policy allows.

## Steps

### 1. Apply the OIDC/IAM Terraform
```bash
cd phase5-cicd/terraform
terraform init
terraform apply
```
Note the `github_actions_role_arn` output.

### 2. Set GitHub repo variables
Repo → Settings → Secrets and variables → Actions → Variables tab (not Secrets — these aren't sensitive, and the whole point of OIDC is not needing secret AWS keys here):
- `AWS_GITHUB_ACTIONS_ROLE_ARN` = the output from step 1
- `AWS_ACCOUNT_ID` = your 12-digit AWS account ID

### 3. Create the namespace and Secret manually (one-time)
```bash
kubectl apply -f k8s/namespace.yaml

kubectl create secret generic finledger-db-credentials \
  --namespace finledger \
  --from-literal=DB_HOST=<rds-endpoint> \
  --from-literal=DB_NAME=finledger \
  --from-literal=DB_USER=finledger_admin \
  --from-literal=DB_PASSWORD=<from-secrets-manager> \
  --from-literal=REDIS_HOST=<elasticache-endpoint>
```
Get the RDS/Redis endpoints from Phase 4's `terraform output`, and the password from Secrets Manager (`terraform output rds_secret_arn`, then `aws secretsmanager get-secret-value`).

### 4. Initial manual deploy (CI only updates images after this exists)
Replace `ACCOUNT_ID` in each `k8s/*.yaml` file with your real AWS account ID, then:
```bash

```
These will initially fail to pull the `:initial` tag (it doesn't exist yet) — that's expected. Pods will sit in `ImagePullBackOff` until step 5 pushes a real image.

### 5. Push to `main` and watch the workflow run
The workflow triggers on changes under `phase2-core-services/services/**` — **double check that path matches your actual repo structure** before relying on it; adjust the `paths:` filter in `.github/workflows/deploy.yml` if your folder names differ.

Each of the three services builds, gets scanned by Trivy, and — only if the scan passes — gets pushed to ECR and deployed via `kubectl set image`.

### 6. Verify
```bash
kubectl get pods -n finledger
kubectl rollout status deployment/account-service -n finledger
```

## Why `image_tag_mutability = "IMMUTABLE"` (set back in Phase 4) matters here

The workflow tags every image with `${{ github.sha }}`, never `:latest`. This isn't a style choice — the ECR repos were deliberately created with immutable tags, so pushing the same tag twice would be **rejected outright**. Every deploy is traceable to an exact commit, and `kubectl rollout undo` always has an unambiguous previous image to roll back to. This is worth being able to explain as a deliberate decision, not an accident of how `docker push` happened to be scripted.

## What's still manual (by design, revisited later)

- **The DB/Redis Secret** is created by hand once. Phase 8 replaces this with External Secrets Operator syncing live from AWS Secrets Manager — real credentials never touch a shell history in the steady state.
- **No ALB/Ingress yet.** Services are `ClusterIP` only, reachable inside the cluster but not from the internet. That needs the AWS Load Balancer Controller installed via Helm first — worth doing as a deliberate next step rather than folding into this phase, since the controller's own IAM policy is large enough to deserve its own careful pass rather than being rushed in here.
- **No automatic rollback on failed Trivy scans beyond blocking the push** — if you want a Slack/email notification on scan failure rather than just a red X in GitHub, that's a small addition to the workflow's `steps` when you're ready for it.