# FinLedger — Phase 2: Core Services (Local)
 
Three FastAPI services + Postgres + Redis, run locally via docker-compose. No AWS involved yet — that's Phase 4.
 
## Services
 
| Service | Port | Responsibility |
|---|---|---|
| `account-service` | 8001 | Create/read accounts, cached balance reads |
| `ledger-service` | 8002 | Read ledger entries, run the zero-sum and balance-reconciliation audit checks |
| `transaction-service` | 8003 | The only service that writes to `transactions` and `ledger_entries` — owns the atomic transfer + idempotency logic |
 
**Why transaction-service alone does the write:** the Phase 1 design doc's core guarantee (a transfer either fully happens or not at all) depends on `transactions`, `ledger_entries`, and the `accounts` balance update all landing in one Postgres transaction. Splitting that write across service boundaries would mean giving up single-database ACID guarantees for a distributed transaction problem this project doesn't need yet. account-service and ledger-service are intentionally read-focused for now.
 
## Run it
 
```bash
docker-compose up -d --build
```
 
Wait for all containers healthy, then sanity check:
 
```bash
curl http://localhost:8001/accounts | python3 -m json.tool
```
 
You should see three seeded accounts: System Treasury, Alice (₹10,000.00), Bob (₹0.00).
 
## Try a transfer manually
 
```bash
curl -X POST http://localhost:8003/transactions/transfer \
  -H "Content-Type: application/json" \
  -d '{
    "idempotency_key": "manual-test-001",
    "from_account_id": "<alice-id-from-above>",
    "to_account_id": "<bob-id-from-above>",
    "amount": 1000,
    "currency": "INR"
  }'
```
 
Run the exact same `curl` command again with the same `idempotency_key` — you'll get the same transaction back, and Bob's balance won't move a second time.
 
## Run the idempotency tests
 
```bash
pip install -r tests/requirements-test.txt
pytest tests/test_idempotency.py -v
```
 
Three tests:
1. **Sequential retry** — same request sent twice in a row → one debit, not two.
2. **Concurrent retry** — same request fired from two threads simultaneously → this is the one that actually proves the DB `UNIQUE` constraint (not just app logic) is doing the work, since app-level "check then insert" logic alone has a race window that only a real concurrent test exposes.
3. **Zero-sum + balance reconciliation** — after all transfers, the ledger-wide audit invariants from the design doc still hold.
## Tear down
 
```bash
docker-compose down -v   # -v also wipes the seeded Postgres data, so next `up` reseeds fresh
```
 
## Known limitations at this stage (intentional, revisited in later phases)
 
- No auth/authz on any endpoint yet.
- One connection per request, no pooling — fine at this scale, a real bottleneck at production traffic (Phase 10 territory).
- `outbox_events` rows are written but nothing publishes them yet — the poller/SQS wiring comes in Phase 6.
- Local dev DB user has full privileges, so the `REVOKE UPDATE, DELETE ON ledger_entries` immutability guard from the design doc isn't enforced yet — that lands with the real IAM/DB role setup in Phase 4.