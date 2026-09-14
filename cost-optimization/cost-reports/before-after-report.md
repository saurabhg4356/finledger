# FinLedger — Cost Optimization: Before/After Report

> **Honesty note, same as Phase 9's postmortem:** the structure and query commands below are complete and correct to run yourself. Every dollar figure is an explicit `[FILL IN]` placeholder — I have no access to your actual AWS billing data, and fabricating cost numbers here would make this document actively misleading in an interview if you were asked a follow-up question about it. Run the commands, replace the placeholders, and this becomes a real artifact.

## Method

1. **"Before" period:** the week(s) running the original Phase 4 default Fargate sizes (`250m CPU / 512Mi memory` per service, set without any real usage data behind them).
2. **Right-size:** run `scripts/right_size_report.py` per service after at least 3 days of real traffic/load, update each Deployment's `resources.requests`/`limits` to the recommended values, redeploy.
3. **"After" period:** an equal-length window running the right-sized values.
4. **Compare** using AWS Cost Explorer, filtered to `project:finledger` tagged resources only, grouped by service.

## Pulling the numbers

```bash
# "Before" period cost, grouped by AWS service
aws ce get-cost-and-usage \
  --time-period Start=[BEFORE_START_DATE],End=[BEFORE_END_DATE] \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{"Tags": {"Key": "project", "Values": ["finledger"]}}'

# "After" period cost, same shape
aws ce get-cost-and-usage \
  --time-period Start=[AFTER_START_DATE],End=[AFTER_END_DATE] \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{"Tags": {"Key": "project", "Values": ["finledger"]}}'
```

Cost Explorer data has up to a 24-hour delay — don't pull "after" numbers the same day you redeploy.

## Right-Sizing Results

| Service | Before (CPU/Memory) | Observed p95 | After (CPU/Memory) | Change |
|---|---|---|---|---|
| account-service | 250m / 512Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| ledger-service | 250m / 512Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| transaction-service | 250m / 512Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| fraud-service | 250m / 512Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| notification-service | 250m / 512Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| outbox-poller | 100m / 256Mi | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |

## Cost Comparison

| AWS Service | Before (7-day cost) | After (7-day cost) | Change |
|---|---|---|---|
| Amazon EKS (Fargate compute) | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |
| Amazon RDS | `[FILL IN]` | `[FILL IN]` | (unaffected by this phase — right-sizing here targets Fargate, not RDS) |
| Amazon ElastiCache | `[FILL IN]` | `[FILL IN]` | (unaffected) |
| **Total (tagged `project:finledger`)** | `[FILL IN]` | `[FILL IN]` | `[FILL IN]` |

## What this phase does NOT claim

- **Right-sizing down doesn't always save money if you were already under-provisioned.** If `right_size_report.py` recommends a HIGHER value than what's currently set, that's not a failure of the exercise — it means the defaults were actually too small, and the "optimization" is fixing a latent performance risk, not cutting cost. State honestly which direction each service moved.
- **This only affects Fargate compute cost.** The EKS control plane fee (~$73/month) and NAT Gateway are unaffected by right-sizing pod resources — right-sizing changes what you pay for the pods themselves, not the fixed infrastructure underneath them.
- **A short observation window (3 days) may not capture real traffic patterns.** If this project doesn't have sustained real load, the p95 values reflect whatever traffic was actually generated (chaos experiments from Phase 9, manual testing) rather than genuine production-like patterns — worth stating that limitation directly rather than presenting a 3-day synthetic-traffic p95 as equivalent to a real production right-sizing exercise.