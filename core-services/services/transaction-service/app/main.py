import json
from uuid import UUID

from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

from app.database import get_connection
from app.cache import get_redis

app = FastAPI(title="transaction-service", version="0.2.0")

IDEMPOTENCY_CACHE_TTL_SECONDS = 60 * 60 * 24  # 24h

# status label values: "completed" | "failed" | "duplicate" (an idempotent
# replay of an already-completed transaction — tracked separately from a
# fresh completion so the failure-rate alert isn't skewed by legitimate retries)
TRANSACTIONS_TOTAL = Counter(
    "finledger_transactions_total",
    "Total transfer attempts by outcome",
    ["status"],
)


class TransferRequest(BaseModel):
    idempotency_key: str = Field(..., min_length=1)
    from_account_id: UUID
    to_account_id: UUID
    amount: int = Field(..., gt=0, description="Amount in minor units (paise), must be positive")
    currency: str = Field(default="INR", min_length=3, max_length=3)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


def _serialize(row):
    return {k: (str(v) if not isinstance(v, (int, float, bool, type(None))) else v) for k, v in row.items()}


@app.post("/transactions/transfer", status_code=201)
def transfer(req: TransferRequest):
    if req.from_account_id == req.to_account_id:
        raise HTTPException(status_code=400, detail="from_account_id and to_account_id must differ")

    r = get_redis()

    cache_key = f"idempotency:{req.idempotency_key}"
    cached_txn_id = r.get(cache_key)
    if cached_txn_id:
        TRANSACTIONS_TOTAL.labels(status="duplicate").inc()
        return _fetch_transaction(cached_txn_id)

    conn = get_connection()
    try:
        # pending_error holds an exception to raise AFTER the `with conn:`
        # block exits normally (and therefore commits) — raising an
        # HTTPException DIRECTLY inside `with conn:` would roll back the
        # whole transaction, including the "mark as failed" update just
        # written, leaving failed attempts with no DB trace at all and
        # breaking idempotency on the failure path. This structure is what
        # makes a "failed" status actually durable.
        pending_error = None

        with conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO transactions
                        (idempotency_key, transaction_type, from_account_id, to_account_id, amount, currency, status)
                    VALUES (%s, 'transfer', %s, %s, %s, %s, 'pending')
                    ON CONFLICT (idempotency_key) DO NOTHING
                    RETURNING id, idempotency_key, status, from_account_id, to_account_id, amount, currency, created_at, completed_at
                    """,
                    (req.idempotency_key, str(req.from_account_id), str(req.to_account_id), req.amount, req.currency),
                )
                txn = cur.fetchone()

                if txn is None:
                    cur.execute(
                        """
                        SELECT id, idempotency_key, status, from_account_id, to_account_id, amount, currency, created_at, completed_at
                        FROM transactions WHERE idempotency_key = %s
                        """,
                        (req.idempotency_key,),
                    )
                    existing = cur.fetchone()
                    TRANSACTIONS_TOTAL.labels(status="duplicate").inc()
                    return _serialize(existing)

                txn_id = txn["id"]

                ids_in_lock_order = sorted([str(req.from_account_id), str(req.to_account_id)])
                cur.execute(
                    "SELECT id, status, cached_balance FROM accounts WHERE id = ANY(%s) ORDER BY id FOR UPDATE",
                    (ids_in_lock_order,),
                )
                locked = {row["id"]: row for row in cur.fetchall()}

                from_acct = locked.get(str(req.from_account_id))
                to_acct = locked.get(str(req.to_account_id))

                if from_acct is None or to_acct is None:
                    cur.execute("UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s", (txn_id,))
                    TRANSACTIONS_TOTAL.labels(status="failed").inc()
                    pending_error = HTTPException(status_code=404, detail="one or both accounts not found")
                elif from_acct["status"] != "active" or to_acct["status"] != "active":
                    cur.execute("UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s", (txn_id,))
                    TRANSACTIONS_TOTAL.labels(status="failed").inc()
                    pending_error = HTTPException(status_code=422, detail="one or both accounts are not active")
                elif from_acct["cached_balance"] < req.amount:
                    cur.execute("UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s", (txn_id,))
                    TRANSACTIONS_TOTAL.labels(status="failed").inc()
                    pending_error = HTTPException(status_code=422, detail="insufficient funds")
                else:
                    cur.execute(
                        """
                        INSERT INTO ledger_entries (transaction_id, account_id, entry_type, amount, currency)
                        VALUES (%s, %s, 'debit', %s, %s), (%s, %s, 'credit', %s, %s)
                        """,
                        (txn_id, str(req.from_account_id), req.amount, req.currency,
                         txn_id, str(req.to_account_id), req.amount, req.currency),
                    )

                    cur.execute(
                        """
                        INSERT INTO outbox_events (transaction_id, event_type, payload)
                        VALUES (%s, 'transaction.completed', %s)
                        """,
                        (txn_id, json.dumps({
                            "transaction_id": str(txn_id),
                            "from_account_id": str(req.from_account_id),
                            "to_account_id": str(req.to_account_id),
                            "amount": req.amount,
                            "currency": req.currency,
                        })),
                    )

                    cur.execute("UPDATE accounts SET cached_balance = cached_balance - %s WHERE id = %s",
                                (req.amount, str(req.from_account_id)))
                    cur.execute("UPDATE accounts SET cached_balance = cached_balance + %s WHERE id = %s",
                                (req.amount, str(req.to_account_id)))

                    cur.execute(
                        """
                        UPDATE transactions SET status = 'completed', completed_at = now() WHERE id = %s
                        RETURNING id, idempotency_key, status, from_account_id, to_account_id, amount, currency, created_at, completed_at
                        """,
                        (txn_id,),
                    )
                    result = _serialize(cur.fetchone())
        # `with conn:` has now exited NORMALLY (no exception), so everything
        # above — including a "failed" status update — is committed.

        if pending_error is not None:
            raise pending_error

        TRANSACTIONS_TOTAL.labels(status="completed").inc()
        r.setex(cache_key, IDEMPOTENCY_CACHE_TTL_SECONDS, result["id"])
        return result

    finally:
        conn.close()


def _fetch_transaction(transaction_id: str):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, idempotency_key, status, from_account_id, to_account_id, amount, currency, created_at, completed_at
                FROM transactions WHERE id = %s
                """,
                (transaction_id,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="transaction not found")
            return _serialize(row)
    finally:
        conn.close()


@app.get("/transactions/{transaction_id}")
def get_transaction(transaction_id: UUID):
    return _fetch_transaction(str(transaction_id))