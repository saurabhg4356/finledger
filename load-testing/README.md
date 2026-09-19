# FinLedger — Phase 11: Load Testing & Scaling

A k6 script that avoids a subtle but serious realism trap, an HPA driven by the Phase 7 SQS metric instead of just CPU, and a breaking-point investigation that starts from a hypothesis instead of a blank slate.

## The realism trap this phase's k6 script avoids

Load testing money transfers using only the Phase 2 seed accounts (Alice, Bob) would mean every single request in the test contends for the same two rows' `FOR UPDATE` locks in `transaction-service`. That measures Postgres row-lock serialization on two specific rows — not the system's real horizontal scalability, and a completely different (and much lower) ceiling that has nothing to do with replica count or compute. `scripts/seed_load_test_accounts.sql` seeds 100 independent, pre-funded accounts specifically so the k6 script can spread lock contention realistically across many row pairs.

## Steps

### 1. Seed load-test accounts
```bash
psql "postgresql://<user>:<password>@<rds-endpoint>:5432/finledger" -f scripts/seed_load_test_accounts.sql
```

### 2. Install k6
```bash
# macOS: brew install k6
# Linux: see https://k6.io/docs/get-started/installation/
```

### 3. Install prometheus-adapter
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  -f k8s/prometheus-adapter-values.yaml
```
Verify the external metric is actually being exposed before relying on it:
```bash
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/finledger/fraud_queue_depth" | jq .
```
If this returns an error instead of a value, the HPA in step 4 will silently fail to scale — this check is worth doing before assuming the HPA itself is broken.

### 4. Apply the HPA
```bash
kubectl apply -f k8s/fraud-service-hpa.yaml
kubectl get hpa -n finledger -w
```

### 5. Port-forward directly to the services (not through the public ALB)
```bash
kubectl port-forward -n finledger svc/account-service 8011:80
kubectl port-forward -n finledger svc/transaction-service 8013:80
```
Testing through the ALB would mean hitting Phase 8's WAF rate limit (100 req/5min on this exact endpoint) partway through, which would look like a breaking point but would actually just be the WAF doing its job — a completely different thing than the service's own capacity.

### 6. Read the hypothesis, then run the test
`results/breaking-point-report.md` states a specific prediction *before* running anything: Phase 2's connection-per-request pattern (flagged as a known limitation at the time) is expected to be the actual bottleneck, not CPU or memory.

```bash
k6 run scripts/k6/transfer_burst.js
```

While it runs, watch Postgres connections and the fraud-service HPA in two other terminals — both watch commands are in the results template.

### 7. Fill in the real results
Same discipline as Phase 9 and Phase 10 — `results/breaking-point-report.md` has the full structure and the hypothesis already written; every actual number is an explicit placeholder for what you observe.

## Why stating the hypothesis before running the test matters

Anyone can run a load test and report a number. Predicting *which specific design decision from three phases earlier* will be the bottleneck, then confirming or refuting that prediction with real data, demonstrates the thing a GCC interviewer actually wants to see: that you understood the system's constraints well enough to know where it would break before you broke it. If the hypothesis turns out to be wrong, say so directly in the report — "I predicted X, the actual bottleneck was Y, here's why I was wrong" is still a strong answer, arguably a more interesting one than being right on the first guess.