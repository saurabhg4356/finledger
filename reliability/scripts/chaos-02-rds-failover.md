# Chaos Experiment 2 — RDS Multi-AZ Failover

## Prerequisite
`rds_multi_az` must be `true` for this experiment — recall from Phase 4's README it defaults to `false` to control cost. Flip it and apply before running this:
```bash
cd phase4-infrastructure/terraform
terraform apply -var="rds_multi_az=true"
```
This itself causes a brief modification window — don't start measuring yet.

## Running the experiment

```bash
# Terminal 1 — continuous health check
kubectl port-forward -n finledger svc/transaction-service 8013:80
python3 scripts/uptime_checker.py --url http://localhost:8013/healthz --interval 0.2

# Terminal 2 — continuous transfer attempts, to measure APPLICATION-level
# impact, not just whether the health endpoint responds. A health check
# passing doesn't prove writes are actually succeeding.
while true; do
  curl -s -X POST http://localhost:8013/transactions/transfer \
    -H "Content-Type: application/json" \
    -d "{\"idempotency_key\": \"chaos-rds-$(date +%s%N)\", \"from_account_id\": \"<alice-id>\", \"to_account_id\": \"<bob-id>\", \"amount\": 100, \"currency\": \"INR\"}" \
    -w " [%{http_code}] %{time_total}s\n" -o /dev/null
  sleep 0.5
done

# Terminal 3 — trigger the actual failover
aws rds reboot-db-instance --db-instance-identifier finledger-postgres --force-failover
```

## What to watch for and record

- **First failed request timestamp** (from Terminal 2's output — first non-200 or timeout)
- **Last failed request timestamp** (last non-200 before requests succeed again)
- **RTO (Recovery Time Objective) = last failed timestamp minus first failed timestamp.** AWS's documented typical range for Multi-AZ failover is 60-120 seconds; treat that as what to expect, not a guarantee — record what you actually observe.
- **RPO (Recovery Point Objective).** RDS Multi-AZ uses synchronous replication to the standby, so committed transactions are not lost — RPO should be effectively zero. What you WILL see is requests that were in-flight at the exact moment of failover returning an error or timing out. These aren't lost data — they never committed. This is the direct payoff of Phase 2's idempotency-key design: the client's correct response to any of these failures is "retry with the same idempotency key," which is provably safe because of the work done all the way back in Phase 2.
- **Zero-sum/balance-drift Gauges during and after** (Phase 7's Grafana) — confirm both stay at 0 throughout, proving the failover didn't corrupt any in-flight ledger writes, only delayed some requests.

## Why this specific experiment is worth walking an interviewer through

Most candidates can say "RDS Multi-AZ gives you failover." Being able to say "I forced one, measured a RTO of exactly N seconds, confirmed RPO was zero because of synchronous replication, and explained why the handful of failed requests during the window were safe to retry because of the idempotency design from three phases earlier" is a materially different, more credible answer.