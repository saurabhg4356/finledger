"""
Consumes transaction.completed events from the fraud SQS queue, applies a
simple rule-based risk score, and records the result. This is deliberately
NOT sophisticated fraud detection — the point of this service in the
portfolio is the async/reliability pattern around it (poison messages, DLQ,
retries), not the scoring logic itself.
"""

import json
import logging
import os
import threading
import time

import boto3
from fastapi import FastAPI, HTTPException

from app.database import get_connection

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("fraud-service")

QUEUE_URL = os.environ["FRAUD_QUEUE_URL"]
HIGH_RISK_THRESHOLD_PAISE = int(os.environ.get("HIGH_RISK_THRESHOLD_PAISE", "500000"))  # ₹5,000

sqs = boto3.client("sqs")
app = FastAPI(title="fraud-service", version="0.1.0")

_last_successful_poll = time.time()

REQUIRED_FIELDS = {"transaction_id", "from_account_id", "to_account_id", "amount", "currency"}


def _score(amount: int) -> tuple[int, bool]:
    risk_score = min(100, (amount * 100) // (HIGH_RISK_THRESHOLD_PAISE * 2))
    flagged = amount >= HIGH_RISK_THRESHOLD_PAISE
    return risk_score, flagged


def _process_message(body: dict):
    # This validation is what turns a malformed message into a poison
    # message on purpose: any required field missing raises, the message is
    # never deleted, and it becomes visible again after the queue's
    # visibility timeout for another attempt.
    missing = REQUIRED_FIELDS - body.keys()
    if missing:
        raise ValueError(f"message missing required fields: {missing}")

    risk_score, flagged = _score(int(body["amount"]))

    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO fraud_checks (transaction_id, risk_score, flagged, reason)
                VALUES (%s, %s, %s, %s)
                """,
                (body["transaction_id"], risk_score, flagged,
                 f"amount={body['amount']} threshold={HIGH_RISK_THRESHOLD_PAISE}"),
            )
    finally:
        conn.close()

    log.info("scored transaction %s: risk=%s flagged=%s", body["transaction_id"], risk_score, flagged)


def consume_loop():
    global _last_successful_poll
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,  # long polling — cheaper and lower-latency than tight-loop short polling
                MessageAttributeNames=["All"],
            )
            messages = response.get("Messages", [])

            for msg in messages:
                receipt_handle = msg["ReceiptHandle"]
                try:
                    body = json.loads(msg["Body"])
                    # SNS wraps the actual payload inside a "Message" field —
                    # unwrap it before validating our own required fields.
                    if "Message" in body:
                        body = json.loads(body["Message"])
                    _process_message(body)
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
                except Exception:
                    log.exception("failed to process message %s — leaving it for retry/DLQ", msg.get("MessageId"))
                    # Deliberately NOT deleting the message here. This is the
                    # entire mechanism: SQS's own redrive_policy (configured
                    # in Terraform) handles moving it to the DLQ after
                    # maxReceiveCount attempts. No custom DLQ code needed.

            _last_successful_poll = time.time()
        except Exception:
            log.exception("consume_loop iteration failed entirely, retrying")
            time.sleep(2)


@app.on_event("startup")
def start_consumer():
    threading.Thread(target=consume_loop, daemon=True).start()


@app.get("/healthz")
def healthz():
    healthy = (time.time() - _last_successful_poll) < 60
    if not healthy:
        raise HTTPException(status_code=503, detail="consumer loop stale")
    return {"status": "ok"}


@app.get("/fraud-checks/{transaction_id}")
def get_fraud_check(transaction_id: str):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, transaction_id, risk_score, flagged, reason, created_at FROM fraud_checks WHERE transaction_id = %s",
                (transaction_id,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="no fraud check recorded for this transaction yet")
            return row
    finally:
        conn.close()