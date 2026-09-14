# FinLedger — Load Test Results: Finding the Breaking Point

> **Honesty note, consistent with Phase 9 and Phase 10:** I have not run this k6 script against live infrastructure — I don't have access to your running cluster. Everything below is the correct structure and the specific hypothesis this project's own design points to, with every actual measured number left as an explicit `[FILL IN]` placeholder. Run `k6 run scripts/k6/transfer_burst.js`, watch the two things listed under "What to watch in parallel" while it runs, and fill this in for real.

## Hypothesis, stated before running the test

Phase 2's `database.py` uses **one new Postgres connection per request, no pooling** — flagged explicitly as a known scaling limit at the time it was written, three phases before this one. The prediction: as request rate climbs, `transaction-service` will exhaust available Postgres connections before CPU or memory becomes the bottleneck, and errors will look like connection refusals or timeouts, not slow-but-successful requests.

This is a genuinely good thing to state as a hypothesis BEFORE running the test — it's a materially stronger interview answer to say "I predicted the connection-per-request pattern would be the limit, then confirmed it under load" than to just report a number with no prior reasoning.

## What to watch in parallel while the k6 test runs

**Postgres connections:**
```bash
psql "<connection-string>" -c "SELECT count(*) FROM pg_stat_activity;"
psql "<connection-string>" -c "SHOW max_connections;"
```
Don't assume a specific `max_connections` value for your instance class — RDS computes it from instance memory via a formula that varies by instance type, and stating an unverified specific number here would be a guess presented as fact. Check it directly.

**Application error rate and the k6 summary output**, plus Grafana's `finledger_transactions_total{status=~"failed"}` rate (Phase 7) alongside it — confirms whether failures are visible at the app-metric level too, not just in k6's own count.

## Results

| Stage (target RPS) | Duration | p95 Latency | Error Rate | Postgres Connections (peak) | Notes |
|---|---|---|---|---|---|
| 10 | 1m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | baseline |
| 30 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |
| 60 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |
| 100 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |
| 150 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |
| 200 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |
| 300 | 2m | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` | |

## The Breaking Point

- **RPS at which errors became significant (>5%):** `[FILL IN]`
- **Was the hypothesis correct?** `[FILL IN — did Postgres connections actually hit their ceiling, or was the real bottleneck something else (Fargate CPU throttling, Redis, ALB target group saturation)? Report what you actually found, even if it contradicts the hypothesis — that's more valuable than confirming what was expected.]`
- **Error shape at the breaking point:** `[FILL IN — 5xx? Connection timeouts? Specific Postgres error like "too many connections"?]`

## Action Items (the direct payoff of this test)

| Action | Rationale |
|---|---|
| Add PgBouncer (transaction pooling mode) in front of RDS, or move to a proper connection pool (e.g., SQLAlchemy's `QueuePool` / `psycopg_pool`) in each service | If the hypothesis was confirmed, this is the concrete fix — same conclusion Phase 2 flagged as a known limitation, now backed by a real measured breaking point instead of a theoretical concern |
| Add an HPA to `transaction-service` itself (CPU-based, or request-latency-based via the same prometheus-adapter path built in this phase) if the breaking point turns out to be compute-bound rather than connection-bound | `[FILL IN — only relevant if the actual bottleneck differs from the hypothesis]` |
| Re-run this test after implementing connection pooling, to measure the improvement with the same methodology | Turns this into a genuine before/after comparison, not a one-off finding |

## fraud-service HPA — did it actually fire?

```bash
kubectl get hpa fraud-service-hpa -n finledger -w
```
`[FILL IN: did fraud-service scale up during the load test as the outbox events piled up faster than 2 replicas could process? What was the peak replica count reached, and how long did it take to scale back down after the load test ended?]`