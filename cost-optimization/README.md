# FinLedger — Phase 10: Cost Optimization

Real CloudWatch Container Insights data driving actual right-sizing decisions, not guessed defaults — and an honest before/after cost comparison.

## The gotcha that shapes this whole phase

The `amazon-cloudwatch-observability` EKS add-on — the one most current tutorials point to as "the way" to enable Container Insights — **does not support Fargate at all**, per AWS's own docs, confirmed via search rather than assumed. Fargate requires the older AWS Distro for OpenTelemetry (ADOT) Collector approach instead, deployed as its own StatefulSet doing Prometheus-style scraping against each node's (i.e., each pod's, since Fargate is 1:1) kubelet cadvisor endpoint.

**I fetched AWS's actual official manifest for this** (`otel-fargate-container-insights.yaml`, 550 lines) rather than reconstruct something this specific from memory — but the fetch went through GitHub's rendered HTML view, since the raw file is blocked from automated fetching by robots.txt. There's a small, explicitly flagged chance the Prometheus regex replacement syntax in `k8s/otel-fargate-container-insights.yaml` picked up a rendering artifact. **Diff it against the live raw file yourself before applying** — the file's own header comment has the exact URL and explains why this matters (a wrong regex here fails silently, with metrics simply not showing up correctly rather than throwing an error).

## Steps

### 1. Apply the Terraform (Fargate profile + IRSA role)
```bash
cd phase10-cost-optimization/terraform
terraform init
terraform apply
```
Note the `adot_collector_role_arn` output.

### 2. Apply the namespace, ServiceAccount, and collector
Replace `<ACCOUNT_ID>` in `k8s/namespace-and-serviceaccount.yaml`, then:
```bash
kubectl apply -f k8s/namespace-and-serviceaccount.yaml
kubectl apply -f k8s/otel-fargate-container-insights.yaml
kubectl get pods -n fargate-container-insights -w
```

### 3. Verify metrics are actually landing in CloudWatch
```bash
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/finledger-cluster
```
Give it 10-15 minutes after the collector pod is Running before expecting data.

### 4. Let it run under real load for a few days
This is not optional or skippable — right-sizing off of 20 minutes of data is barely better than the guessed defaults it's replacing. Use the project genuinely (or run the Phase 9 chaos experiments again, which at least generates real traffic patterns) for at least 3 days before pulling p95 numbers.

### 5. Pull p95 usage and get a recommendation
```bash
kubectl get pods -n finledger -l app=transaction-service -o jsonpath='{.items[*].metadata.name}'
python3 scripts/right_size_report.py \
  --service transaction-service \
  --pods <pod-names-from-above> \
  --days 3 \
  --current-cpu-millicores 250 \
  --current-memory-mib 512
```
Repeat per service.

### 6. Apply the recommended sizes
Update each Deployment's `resources.requests`/`limits` (in the Phase 5/6 k8s manifests) to the recommended values, redeploy through the existing CI pipeline.

### 7. Fill in the real cost report
`cost-reports/before-after-report.md` — **read its honesty note first.** Run the `aws ce get-cost-and-usage` commands it provides for both the before and after windows, and replace every placeholder with what you actually observe.

## What "done" looks like for this phase

Not a specific dollar amount — a filled-in report with real p95 numbers, a real before/after cost comparison, and an honest statement of which services moved up vs. down in their resource allocation. Being able to say "I found `X` was over-provisioned by `Y`% and `Z` was actually under-provisioned, here's the real Cost Explorer data" is a materially stronger interview answer than "I set some numbers and the bill went down," even if the actual dollar savings on a small portfolio project are modest.