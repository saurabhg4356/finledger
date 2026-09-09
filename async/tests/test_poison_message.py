"""
Proves two things about the Phase 6 async pipeline:

1. A malformed ("poison") message sent to the fraud queue does NOT block a
   valid message sent right after it — SQS's non-FIFO delivery means there's
   no head-of-line blocking, so the good message still gets processed even
   while the bad one is failing and being retried.
2. The poison message eventually lands in the fraud DLQ on its own, via
   SQS's redrive_policy — no custom application code required to detect it.

Requires AWS credentials with SQS access configured locally (this talks
directly to real SQS, not through any FinLedger service), plus these env
vars (from `terraform output` in async/terraform):
    FRAUD_QUEUE_URL, FRAUD_DLQ_URL

Also requires the FinLedger stack itself to be reachable, to create one real
transfer (fraud_checks.transaction_id has a foreign key to transactions.id,
so a made-up ID would fail for reasons unrelated to what this test is
actually proving).

This test is slower than the others by design — proving DLQ arrival honestly
requires waiting through real retries and real visibility timeouts, not
mocking them away:
    pytest tests/test_poison_message.py -v -s
"""

import json
import os
import time
import uuid

import boto3
import pytest
import requests

ACCOUNT_SERVICE = os.environ.get("ACCOUNT_SERVICE_URL", "http://localhost:8011")
TRANSACTION_SERVICE = os.environ.get("TRANSACTION_SERVICE_URL", "http://localhost:8013")
FRAUD_SERVICE = os.environ.get("FRAUD_SERVICE_URL", "http://localhost:8004")

FRAUD_QUEUE_URL = os.environ["FRAUD_QUEUE_URL"]
FRAUD_DLQ_URL = os.environ["FRAUD_DLQ_URL"]

sqs = boto3.client("sqs")


@pytest.fixture(scope="module")
def real_transaction():
    """A genuine completed transfer, so the fraud_checks foreign key is satisfiable."""
    accounts = requests.get(f"{ACCOUNT_SERVICE}/accounts").json()
    alice = next(a for a in accounts if a["owner_name"] == "Alice")
    bob = next(a for a in accounts if a["owner_name"] == "Bob")

    payload = {
        "idempotency_key": f"poison-test-{uuid.uuid4()}",
        "from_account_id": alice["id"],
        "to_account_id": bob["id"],
        "amount": 250,
        "currency": "INR",
    }
    resp = requests.post(f"{TRANSACTION_SERVICE}/transactions/transfer", json=payload)
    assert resp.status_code == 201
    return {**resp.json(), **payload}


def test_valid_message_survives_poison_message_ahead_of_it(real_transaction):
    # A poison message: valid JSON, but missing the fields fraud-service requires.
    poison_body = json.dumps({"garbage": "not a real transaction event", "id": str(uuid.uuid4())})

    # A valid message matching exactly what the outbox-poller would actually publish.
    valid_body = json.dumps({
        "transaction_id": real_transaction["id"],
        "from_account_id": real_transaction["from_account_id"],
        "to_account_id": real_transaction["to_account_id"],
        "amount": real_transaction["amount"],
        "currency": real_transaction["currency"],
    })

    # Poison message sent FIRST, deliberately, to test it doesn't block what follows.
    sqs.send_message(QueueUrl=FRAUD_QUEUE_URL, MessageBody=poison_body)
    sqs.send_message(QueueUrl=FRAUD_QUEUE_URL, MessageBody=valid_body)

    # Poll fraud-service's read endpoint for up to 30s — the valid message
    # should be processed well within this window regardless of what's
    # happening to the poison message in parallel.
    deadline = time.time() + 30
    result = None
    while time.time() < deadline:
        resp = requests.get(f"{FRAUD_SERVICE}/fraud-checks/{real_transaction['id']}")
        if resp.status_code == 200:
            result = resp.json()
            break
        time.sleep(2)

    assert result is not None, "valid message was never processed — it may have been blocked by the poison message ahead of it"
    assert result["transaction_id"] == real_transaction["id"]


def test_poison_message_lands_in_dlq():
    marker = str(uuid.uuid4())
    poison_body = json.dumps({"garbage": "no required fields", "marker": marker})

    sqs.send_message(QueueUrl=FRAUD_QUEUE_URL, MessageBody=poison_body)

    # redrive_policy is maxReceiveCount=3 with a 30s visibility timeout, so
    # the message needs roughly 3 x 30s = 90s of failed attempts before SQS
    # moves it to the DLQ. Poll generously past that.
    deadline = time.time() + 150
    found = False
    while time.time() < deadline and not found:
        response = sqs.receive_message(
            QueueUrl=FRAUD_DLQ_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=10,
        )
        for msg in response.get("Messages", []):
            if marker in msg["Body"]:
                found = True
                # Clean up: delete it from the DLQ now that we've confirmed it arrived.
                sqs.delete_message(QueueUrl=FRAUD_DLQ_URL, ReceiptHandle=msg["ReceiptHandle"])
                break

    assert found, "poison message never appeared in the DLQ within the expected retry window"