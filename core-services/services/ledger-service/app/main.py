from uuid import UUID

from fastapi import FastAPI

from app.database import get_connection

app = FastAPI(title="ledger-service", version="0.1.0")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/ledger/transactions/{transaction_id}/entries")
def get_entries_for_transaction(transaction_id: UUID):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, transaction_id, account_id, entry_type, amount, currency, created_at
                FROM ledger_entries WHERE transaction_id = %s ORDER BY created_at
                """,
                (str(transaction_id),),
            )
            return cur.fetchall()
    finally:
        conn.close()


@app.get("/ledger/accounts/{account_id}/entries")
def get_entries_for_account(account_id: UUID):
    """Effectively a statement / transaction history for one account."""
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, transaction_id, entry_type, amount, currency, created_at
                FROM ledger_entries WHERE account_id = %s ORDER BY created_at DESC
                """,
                (str(account_id),),
            )
            return cur.fetchall()
    finally:
        conn.close()


@app.get("/ledger/audit/zero-sum-check")
def zero_sum_check():
    """
    Invariant #1 from the Phase 1 design doc: every transaction's ledger
    entries must sum to zero (debits negative, credits positive). Any row
    returned here is a real bug, not a warning — this becomes an AlertManager
    rule in Phase 2's observability step.
    """
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT transaction_id,
                       SUM(CASE WHEN entry_type = 'credit' THEN amount ELSE -amount END) AS drift
                FROM ledger_entries
                GROUP BY transaction_id
                HAVING SUM(CASE WHEN entry_type = 'credit' THEN amount ELSE -amount END) != 0
                """
            )
            violations = cur.fetchall()
            return {"violations": violations, "clean": len(violations) == 0}
    finally:
        conn.close()


@app.get("/ledger/audit/balance-reconciliation")
def balance_reconciliation():
    """
    Invariant #2: accounts.cached_balance must equal the sum of that
    account's ledger_entries. Drift here means the cached balance and the
    source of truth disagree — a real production concern, not academic.
    """
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT a.id AS account_id,
                       a.owner_name,
                       a.cached_balance,
                       COALESCE(SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE -le.amount END), 0) AS ledger_balance,
                       a.cached_balance - COALESCE(SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE -le.amount END), 0) AS drift
                FROM accounts a
                LEFT JOIN ledger_entries le ON le.account_id = a.id
                GROUP BY a.id, a.owner_name, a.cached_balance
                HAVING a.cached_balance != COALESCE(SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE -le.amount END), 0)
                """
            )
            violations = cur.fetchall()
            return {"violations": violations, "clean": len(violations) == 0}
    finally:
        conn.close()