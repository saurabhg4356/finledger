# Incident Postmortem: RDS Multi-AZ Failover (Deliberate Chaos Test)

**Title:** Deliberate RDS Multi-AZ failover — transaction-service impact
**Date:** `[FILL IN — date you actually ran this]`
**Author:** Saurabh
**Severity:** Medium (deliberate test, not a real production incident)
**Status:** Resolved

> **Honesty note on this document:** this postmortem's structure and expected-behavior narrative are written out in full, but the specific measured numbers below (marked `[MEASURE AND FILL IN]`) are placeholders — I have not run this against live infrastructure myself, and fabricating specific timing numbers here would defeat the entire point of a postmortem being evidence-based. Run `scripts/chaos-02-rds-failover.md`, replace every placeholder with what you actually observed, and this becomes a real, presentable artifact. Until then, treat this as a filled-in template showing what good looks like, not a claimed result.

## Summary
A Multi-AZ failover was deliberately triggered on the FinLedger RDS Postgres instance (`aws rds reboot-db-instance --force-failover`) to measure real application-level impact, RTO, and RPO — rather than relying on AWS's documentation of expected behavior without having verified it against this specific application's failure handling.

## Impact
- **Affected component:** `transaction-service` (the only service with a synchronous write path to Postgres)
- **User-facing impact:** transfer requests submitted during the failover window received errors or timeouts; no requests were silently lost or double-processed
- **Duration of impact:** `[MEASURE AND FILL IN — from uptime_checker.py's summary output]`
- **Data integrity:** confirmed intact — see "Root Cause" and "Verification" below

## Timeline
All timestamps UTC. Fill in actual observed times from the three terminals in `chaos-02-rds-failover.md`.

| Time | Event |
|---|---|
| `[FILL IN]` | Failover triggered via `aws rds reboot-db-instance --force-failover` |
| `[FILL IN]` | First failed/timed-out transfer request observed in Terminal 2 |
| `[FILL IN]` | `uptime_checker.py` recorded the health endpoint going DOWN |
| `[FILL IN]` | `uptime_checker.py` recorded RECOVERY (health endpoint back to 200) |
| `[FILL IN]` | First successful transfer request after the failover |
| `[FILL IN]` | Confirmed Grafana's `finledger_ledger_zero_sum_violations` and `finledger_ledger_balance_drift_violations` remained at 0 throughout |

## Root Cause
Not a failure in the traditional sense — a deliberate, controlled disruption. The underlying mechanism: RDS Multi-AZ promotes the synchronous standby to primary and updates the DNS CNAME for the instance endpoint; any connection held by the application against the old primary breaks and must reconnect against the (same, unchanged) endpoint address once DNS propagates and the new primary accepts connections.

## Detection
In a real incident, this would be detected by AlertManager (Phase 7) rather than a human watching a terminal — specifically, a sustained drop in `finledger_transactions_total{status="completed"}` rate or, if built out further, a direct RDS `DatabaseConnections`-style CloudWatch alarm. This chaos test used direct observation (the uptime checker and manual `curl` loop) since the point was to measure impact firsthand, not to test the alerting pipeline itself — that's a legitimate follow-up test in its own right, worth doing as a separate deliberate exercise.

## Resolution
Self-resolving — RDS completes the failover automatically; no manual intervention was required or performed. The application's existing connection-per-request pattern (see Phase 2's `database.py`, noted there as a known scaling limit) meant no long-lived connection pool needed to be manually recycled; each new request simply opened a fresh connection against the (by-then-recovered) endpoint.

## Metrics
- **MTTD:** N/A for a deliberate test — detection was immediate by design (the tester triggered it)
- **MTTR:** `[MEASURE AND FILL IN]`
- **RTO:** `[MEASURE AND FILL IN — compare against AWS's documented typical 60-120s range]`
- **RPO:** `0` — RDS Multi-AZ uses synchronous replication; no committed transaction was lost. Requests that failed during the window never committed in the first place, so their "loss" is a failed request, not a data-loss event.

## Verification
- Zero-sum and balance-reconciliation Gauges (Phase 7) confirmed at 0 both during and after the failover window.
- Any transfer requests that failed during the window were safe to retry with the same `idempotency_key` — this is the direct, concrete payoff of the idempotency design from Phase 2's design doc, three phases before this test was ever run. `[FILL IN: did you actually retry a failed request with its original idempotency_key and confirm it succeeded exactly once? If so, note the transaction ID here as evidence.]`

## Action Items
| Action | Owner | Status |
|---|---|---|
| Build a CloudWatch alarm on RDS failover events (`RDS-EVENT-0006`), wired to the same AlertManager receiver as Phase 7's other critical alerts | Saurabh | Not started |
| Re-run this test with `rds_multi_az` left `true` for a full week to see if failover behavior differs under any real accumulated connection load, vs. this single clean test | Saurabh | Not started |
| Add a synthetic canary transfer (one per minute, via a scheduled Lambda or CronJob) so a real production failover would be detected within ~60s automatically, not only when someone happens to be watching | Saurabh | Not started |

## What Went Well
- The idempotency design paid off exactly as intended — this is the single clearest validation in the whole project that a Phase 2 design decision correctly anticipated a Phase 9 failure mode, three phases and many weeks apart.
- No manual intervention was required for the database to recover — Multi-AZ did exactly what it's supposed to do with zero operator action.
- `[FILL IN anything else that surprised you positively during the real run]`