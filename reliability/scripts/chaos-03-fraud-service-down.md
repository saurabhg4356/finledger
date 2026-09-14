# Chaos Experiment 3 — Kill fraud-service, Prove Graceful Degradation

This is the direct payoff of Phase 6's async decoupling decision. If fraud scoring were synchronous (transaction-service calling fraud-service directly and waiting), killing fraud-service would break transfers. Because they're connected only through SNS/SQS, they shouldn't be.

## Running the experiment

```bash
# Terminal 1 — health/transfer loop, same as Experiment 2
kubectl port-forward -n finledger svc/transaction-service 8013:80
python3 scripts/uptime_checker.py --url http://localhost:8013/healthz --interval 0.2

# Terminal 2 — kill fraud-service entirely
kubectl scale deployment/fraud-service -n finledger --replicas=0

# Terminal 3 — keep making transfers throughout
while true; do
  curl -s -X POST http://localhost:8013/transactions/transfer \
    -H "Content-Type: application/json" \
    -d "{\"idempotency_key\": \"chaos-fraud-$(date +%s%N)\", \"from_account_id\": \"<alice-id>\", \"to_account_id\": \"<bob-id>\", \"amount\": 100, \"currency\": \"INR\"}" \
    -w " [%{http_code}]\n" -o /dev/null
  sleep 1
done
```

## What to watch for

1. **Every transfer in Terminal 3 should keep returning 201** the entire time fraud-service is at 0 replicas. If any transfer fails or hangs waiting on fraud-service, that's a regression from the Phase 6 design — the whole point of SNS/SQS decoupling is that a downstream consumer being down cannot block the write path.
2. **Watch the queue depth metric build up** (Phase 7's Grafana, `aws_sqs_approximate_number_of_messages_visible_average{queue_name="finledger-fraud-queue"}`) — it should climb steadily while fraud-service is down, since the outbox-poller keeps publishing but nothing is consuming.
3. **After a few minutes, restore fraud-service:**
```bash
   kubectl scale deployment/fraud-service -n finledger --replicas=2
```
4. **Watch the backlog drain** — queue depth should fall back toward 0 as the restored consumers catch up on the accumulated messages. Confirm via `GET /fraud-checks/{transaction_id}` on a few transactions made while fraud-service was down — they should now show a recorded fraud check, proving no events were lost, only delayed.

## What NOT to expect

Don't expect the `QueueBacklogGrowing` alert from Phase 7 to fire unless the outage is long enough or high-volume enough to cross its threshold (100 messages sustained for 10 minutes) — a short manual test may not trigger it, which is fine and expected; it's tuned for a sustained real problem, not a 2-minute demo. Note the queue depth graph shape either way — that's the real evidence.

## What to record for the postmortem

- Whether any transfer failed or was delayed during the fraud-service outage (expected: no)
- Peak queue depth reached
- Time to drain the backlog after restoring fraud-service
- Confirmation that a transaction created during the outage got its fraud check recorded after recovery