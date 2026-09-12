# FinLedger — Phase 7: Observability

Prometheus/Grafana/AlertManager via the `kube-prometheus-stack` Helm chart, tuned for EKS Fargate's real constraints — plus business-level metrics (transaction success rate, ledger zero-sum/balance-drift violations) and queue depth via a CloudWatch bridge.

## The one thing to understand before anything else: node-exporter cannot run here

`prometheus-node-exporter` is a DaemonSet. **Fargate does not support DaemonSets at all** — this isn't a "needs tolerations" situation like some guides suggest; it's categorically unsupported, since Fargate deliberately doesn't expose an accessible host for a per-node agent to run on. I confirmed this is still current guidance via search rather than assuming it from training data. The values file below sets `prometheus-node-exporter.enabled: false` — this is the *correct* fix, not a workaround, since there's no "node" concept to introspect on Fargate in the first place. `kube-state-metrics` (a normal Deployment) still gives you pod/deployment-level metrics without it.

## Required updates to earlier phases

**1. Add `prometheus-client` to two services' dependencies:**

phase2-core-services/services/transaction-service/requirements.txt
phase2-core-services/services/ledger-service/requirements.txt

prometheus-client==0.21.0


**2. Replace two service files** with the updated versions in `services-updates/` — they add the metrics/Gauges described below. While updating `transaction-service/app/main.py`, I also fixed a real bug carried over from Phase 2: failed transfers were raising their error *inside* the DB transaction block, which rolled back the "mark as failed" status update along with everything else — meaning a failed attempt left no trace in the database at all, and a retry with the same idempotency key would be treated as brand new instead of returning the recorded failure. The updated version commits the failure status before raising. Worth understanding this fix, not just applying it — it's a good example of a subtle correctness bug that only shows up when you think carefully about what "roll back on exception" actually rolls back.

**3. Name the container ports in Phase 5's Service manifests.** ServiceMonitors reference a Service's port by *name*, not number — but the Phase 5 Services (`account-service.yaml`, `ledger-service.yaml`, `transaction-service.yaml`) don't name theirs. Add `name: http` to the `ports:` block in `ledger-service.yaml` and `transaction-service.yaml`:
```yaml
  ports:
    - name: http
      port: 80
      targetPort: 8002  # (or 8003 for transaction-service)
```

**4. Rebuild and redeploy** `transaction-service` and `ledger-service` through the existing Phase 5 CI pipeline after these changes.

## Steps

### 1. Apply the monitoring Fargate profile + CloudWatch exporter IAM role
```bash
cd phase7-observability/terraform
terraform init
terraform apply
```
Note the `cloudwatch_exporter_role_arn` output.

### 2. Install Helm (if not already)
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 3. Create the monitoring namespace
```bash
kubectl apply -f k8s/monitoring-namespace.yaml
```

### 4. Install kube-prometheus-stack
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f observability/helm/kube-prometheus-stack-values.yaml \
  --set grafana.adminPassword=<choose-a-real-password-here>
```

### 5. Install the CloudWatch exporter (YACE) for queue depth
```bash
helm repo add yet-another-cloudwatch-exporter https://nerdswords.github.io/helm-charts
helm repo update
helm install cloudwatch-exporter yet-another-cloudwatch-exporter/yet-another-cloudwatch-exporter \
  --namespace monitoring \
  -f observability/helm/cloudwatch-exporter-values.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<cloudwatch_exporter_role_arn from step 1>
```
Then verify the actual Service name/port it created and fix `k8s/service-monitors.yaml`'s `cloudwatch-exporter` ServiceMonitor to match — flagged honestly as unverified in that file's comments rather than guessed and presented as certain.
```bash
kubectl get svc -n monitoring
```

### 6. Apply the ServiceMonitors and alert rules
```bash
kubectl apply -f k8s/service-monitors.yaml
kubectl apply -f k8s/prometheus-rules.yaml
```

### 7. Verify Prometheus is actually scraping the right targets
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```
Open `http://localhost:9090/targets` — you should see `transaction-service`, `ledger-service`, and `cloudwatch-exporter` all `UP`. If any show as not discovered at all (not even listed), that's almost always the namespace-selector trap explained in the Helm values comments, or the named-port mismatch from step 3 above.

### 8. Access Grafana
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```
Log in with `admin` / the password you set in step 4. The default kube-prometheus-stack dashboards work immediately; a custom FinLedger business-metrics dashboard is a natural next addition once you've confirmed the raw metrics are flowing.

### 9. Wire a real AlertManager receiver
`helm/kube-prometheus-stack-values.yaml` ships with empty `webhook_configs` on purpose — a fabricated-looking Slack URL that silently does nothing would be worse than an honest placeholder. Add your real Slack incoming webhook (or email/PagerDuty config) before this alerting is actually useful.

### 10. Prove it end-to-end
Make a transfer, then check Prometheus for `finledger_transactions_total{status="completed"}` increasing, and confirm `finledger_ledger_zero_sum_violations` and `finledger_ledger_balance_drift_violations` both read `0`. Then, using Phase 6's DLQ test, watch `aws_sqs_approximate_number_of_messages_visible_average{queue_name="finledger-fraud-dlq"}` go from 0 to 1 and trigger the `DeadLetterQueueHasMessages` alert — this is the single best demo moment in the whole project: a poison message you deliberately sent shows up as a real alert within minutes, not something you have to explain happened, actually visible.

## What's still missing (honest, not exhaustive)

- **No Grafana dashboard JSON provided yet** — the metrics exist and are scrapeable; building a dashboard around them is worth doing as a deliberate next pass rather than a rushed, generic one bolted on here.
- **AlertManager has no real receiver configured** until you do step 9.
- **No persistent storage for Prometheus** — accepted trade-off, explained in the Helm values comments, consistent with this project being destroyed between sessions anyway.