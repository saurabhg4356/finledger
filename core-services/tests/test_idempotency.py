"""
Proves the core Phase 2 guarantee: retrying the same transfer request with the
same idempotency_key — whether sequentially or concurrently — results in
exactly ONE debit/credit pair, never two.

Run against a live docker-compose stack:
    docker-compose up -d --build
    pip install -r tests/requirements-test.txt
    pytest tests/test_idempotency.py -v
"""

import os
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest
import requests

ACCOUNT_SERVICE = os.environ.get("ACCOUNT_SERVICE_URL", "http://localhost:8011")
LEDGER_SERVICE = os.environ.get("LEDGER_SERVICE_URL", "http://localhost:8012")
TRANSACTION_SERVICE = os.environ.get("TRANSACTION_SERVICE_URL", "http://localhost:8013")

TRANSFER_AMOUNT = 500  # paise


@pytest.fixture(scope="module")
def seeded_accounts():
    """Alice and Bob are created by db/init.sql on first container startup."""
    accounts = requests.get(f"{ACCOUNT_SERVICE}/accounts").json()
    alice = next(a for a in accounts if a["owner_name"] == "Alice")
    bob = next(a for a in accounts if a["owner_name"] == "Bob")
    return alice, bob


def _balance(account_id):
    return requests.get(f"{ACCOUNT_SERVICE}/accounts/{account_id}/balance").json()["balance"]


def _entries_for_transaction(transaction_id):
    return requests.get(f"{LEDGER_SERVICE}/ledger/transactions/{transaction_id}/entries").json()


def test_sequential_retry_no_double_debit(seeded_accounts):
    """The straightforward case: client sends the same request twice in a row
    (e.g. it timed out waiting for the first response and retried)."""
    alice, bob = seeded_accounts
    idempotency_key = f"test-sequential-{uuid.uuid4()}"

    alice_before = _balance(alice["id"])
    bob_before = _balance(bob["id"])

    payload = {
        "idempotency_key": idempotency_key,
        "from_account_id": alice["id"],
        "to_account_id": bob["id"],
        "amount": TRANSFER_AMOUNT,
        "currency": "INR",
    }

    first = requests.post(f"{TRANSACTION_SERVICE}/transactions/transfer", json=payload)
    second = requests.post(f"{TRANSACTION_SERVICE}/transactions/transfer", json=payload)

    assert first.status_code == 201
    assert second.status_code == 201

    first_body = first.json()
    second_body = second.json()

    # Both requests must resolve to the SAME transaction, not two different ones.
    assert first_body["id"] == second_body["id"]

    txn_id = first_body["id"]
    entries = _entries_for_transaction(txn_id)
    assert len(entries) == 2, f"expected exactly 2 ledger entries (1 debit + 1 credit), got {len(entries)}"

    alice_after = _balance(alice["id"])
    bob_after = _balance(bob["id"])

    assert alice_after == alice_before - TRANSFER_AMOUNT, "Alice was debited more than once"
    assert bob_after == bob_before + TRANSFER_AMOUNT, "Bob was credited more than once"


def test_concurrent_retry_no_double_debit(seeded_accounts):
    """The harder case: two requests with the same idempotency_key arrive at
    almost exactly the same time (e.g. a client-side retry firing before the
    first response returns). This is what actually proves the UNIQUE
    constraint — not just application-level logic — is what prevents the
    double debit, since app logic alone has a race window here."""
    alice, bob = seeded_accounts
    idempotency_key = f"test-concurrent-{uuid.uuid4()}"

    alice_before = _balance(alice["id"])
    bob_before = _balance(bob["id"])

    payload = {
        "idempotency_key": idempotency_key,
        "from_account_id": alice["id"],
        "to_account_id": bob["id"],
        "amount": TRANSFER_AMOUNT,
        "currency": "INR",
    }

    def fire():
        return requests.post(f"{TRANSACTION_SERVICE}/transactions/transfer", json=payload)

    with ThreadPoolExecutor(max_workers=2) as pool:
        f1 = pool.submit(fire)
        f2 = pool.submit(fire)
        r1, r2 = f1.result(), f2.result()

    assert r1.status_code == 201
    assert r2.status_code == 201
    assert r1.json()["id"] == r2.json()["id"], "concurrent retries resolved to two different transactions"

    txn_id = r1.json()["id"]
    entries = _entries_for_transaction(txn_id)
    assert len(entries) == 2, f"expected exactly 2 ledger entries, got {len(entries)} — this means a double-debit occurred"

    alice_after = _balance(alice["id"])
    bob_after = _balance(bob["id"])

    assert alice_after == alice_before - TRANSFER_AMOUNT
    assert bob_after == bob_before + TRANSFER_AMOUNT


def test_zero_sum_invariant_holds():
    """After all the above transfers, the ledger-wide audit check must still
    report clean — this is the same query Phase 9's chaos experiments will
    monitor continuously."""
    result = requests.get(f"{LEDGER_SERVICE}/ledger/audit/zero-sum-check").json()
    assert result["clean"], f"zero-sum violations found: {result['violations']}"

    result = requests.get(f"{LEDGER_SERVICE}/ledger/audit/balance-reconciliation").json()
    assert result["clean"], f"balance reconciliation violations found: {result['violations']}"