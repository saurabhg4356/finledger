import logging
import threading
import time
from uuid import UUID

from fastapi import FastAPI, Response
from prometheus_client import Gauge, generate_latest, CONTENT_TYPE_LATEST

from app.database import get_connection

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ledger-service")

app = FastAPI(title="ledger-service", version="0.2.0")

AUDIT_INTERVAL_SECONDS = 30

ZERO_SUM_VIOLATIONS = Gauge(
    "finledger_ledger_zero_sum_violations",
    "Count of transactions whose ledger entries do not sum to zero (should always be 0)",
)
BALANCE_DRIFT_VIOLATIONS = Gauge(
    "finledger_ledger_balance_drift_violations",
    "Count of accounts whose cached_balance disagrees with the sum of their ledger_entries (should always be 0)",
)


def _run_audit_once():
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
            zero_sum_count = len(cur.fetchall())

            cur.execute(
                """
                SELECT a.id
                FROM accounts a
                LEFT JOIN ledger_entries le ON le.account_id = a.id
                GROUP BY a.id, a.cached_balance
                HAVING a.cached_balance != COALESCE(SUM(CASE WHEN le.entry_type = 'credit' THEN le.amount ELSE -le.amount END), 0)
                """
            )
            balance_drift_count = len(cur.fetchall())

        ZERO_SUM_VIOLATIONS.set(zero_sum_count)
        BALANCE_DRIFT_VIOLATIONS.set(balance_drift_count)

        if zero_sum_count or balance_drift_count:
            log.error(
                "LEDGER INTEGRITY VIOLATION — zero_sum=%s balance_drift=%s",
                zero_sum_count, balance_drift_count,
            )
    finally:
        conn.close()


def _audit_loop():
    while True:
        try:
            _run_audit_once()
        except Exception:
            log.exception("audit loop iteration failed — Gauges will show their last known value, not necessarily 0")
        time.sleep(AUDIT_INTERVAL_SECONDS)


@app.on_event("startup")
def start_audit_loop():
    threading.Thread(target=_audit_loop, daemon=True).start()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


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
    """On-demand version — unchanged from Phase 2. The Gauge above is the
    continuously-updated version this alert rules actually watch."""
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