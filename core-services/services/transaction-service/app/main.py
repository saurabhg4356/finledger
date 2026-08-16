import json
from decimal import Decimal
from uuid import UUID

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.database import get_connection
from app.cache import get_redis

app = FastAPI(title="transaction-service", version="0.1.0")

IDEMPOTENCY_CACHE_TTL_SECONDS = 60 * 60 * 24  # 24h


class TransferRequest(BaseModel):
    idempotency_key: str = Field(..., min_length=1)
    from_account_id: UUID
    to_account_id: UUID
    amount: int = Field(..., gt=0, description="Amount in minor units (paise), must be positive")
    currency: str = Field(default="INR", min_length=3, max_length=3)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


def _serialize(row):
    """psycopg2 RealDictRow -> plain dict with UUIDs/timestamps as strings for JSON/Redis."""
    return {k: (str(v) if not isinstance(v, (int, float, bool, type(None))) else v) for k, v in row.items()}


@app.post("/transactions/transfer", status_code=201)
def transfer(req: TransferRequest):
    if req.from_account_id == req.to_account_id:
        raise HTTPException(status_code=400, detail="from_account_id and to_account_id must differ")

    r = get_redis()

    # --- Fast path: Redis pre-check ---------------------------------------
    # This is a latency optimization only. It is NEVER the source of truth —
    # the UNIQUE constraint on transactions.idempotency_key is what actually
    # guarantees no double-debit. If Redis is down or the key simply isn't
    # cached yet, the DB constraint still catches it below.
    cache_key = f"idempotency:{req.idempotency_key}"
    cached_txn_id = r.get(cache_key)
    if cached_txn_id:
        return _fetch_transaction(cached_txn_id)

    conn = get_connection()
    try:
        with conn:  # commits on success, rolls back on any exception
            with conn.cursor() as cur:
                # --- Claim the idempotency key --------------------------------
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
                    # Someone already claimed this key — this is a retry.
                    # Return the existing result instead of processing anything.
                    cur.execute(
                        """
                        SELECT id, idempotency_key, status, from_account_id, to_account_id, amount, currency, created_at, completed_at
                        FROM transactions WHERE idempotency_key = %s
                        """,
                        (req.idempotency_key,),
                    )
                    existing = cur.fetchone()
                    return _serialize(existing)

                txn_id = txn["id"]

                # --- Lock both accounts in a GLOBAL, consistent order ----------
                # Locking in request order (from, then to) would deadlock against
                # a concurrent transfer going the opposite direction between the
                # same two accounts. Locking by sorted account ID instead means
                # every transaction acquires locks in the same global order, so
                # circular waits can't happen.
                ids_in_lock_order = sorted([str(req.from_account_id), str(req.to_account_id)])
                cur.execute(
                    "SELECT id, status, cached_balance FROM accounts WHERE id = ANY(%s::uuid[]) ORDER BY id FOR UPDATE",
                    (ids_in_lock_order,),
            )
                locked = {row["id"]: row for row in cur.fetchall()}

                from_acct = locked.get(str(req.from_account_id))
                to_acct = locked.get(str(req.to_account_id))

                if from_acct is None or to_acct is None:
                    cur.execute(
                        "UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s",
                        (txn_id,),
                    )
                    raise HTTPException(status_code=404, detail="one or both accounts not found")

                if from_acct["status"] != "active" or to_acct["status"] != "active":
                    cur.execute(
                        "UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s",
                        (txn_id,),
                    )
                    raise HTTPException(status_code=422, detail="one or both accounts are not active")

                if from_acct["cached_balance"] < req.amount:
                    cur.execute(
                        "UPDATE transactions SET status = 'failed', completed_at = now() WHERE id = %s",
                        (txn_id,),
                    )
                    raise HTTPException(status_code=422, detail="insufficient funds")

                # --- Balancing ledger entries -----------------------------------
                cur.execute(
                    """
                    INSERT INTO ledger_entries (transaction_id, account_id, entry_type, amount, currency)
                    VALUES (%s, %s, 'debit', %s, %s), (%s, %s, 'credit', %s, %s)
                    """,
                    (txn_id, str(req.from_account_id), req.amount, req.currency,
                     txn_id, str(req.to_account_id), req.amount, req.currency),
                )

                # --- Outbox event (see Phase 1 doc, Section 5) ------------------
                # Written in the SAME transaction as the ledger entries so the
                # event's existence is exactly as reliable as the transfer itself.
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

                # --- Cached balances (fast-read optimization) --------------------
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

        # Cache AFTER commit succeeds — never cache an outcome that might still roll back.
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