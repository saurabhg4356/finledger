"""
Consumes transaction.completed events from the notification SQS queue and
"sends" a notification — simulated here as a logged + persisted message
rather than a real email/SMS integration, since the point of this service in
the portfolio is the same async reliability pattern as fraud-service, applied
to a second, fully independent consumer of the same event stream.
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
log = logging.getLogger("notification-service")

QUEUE_URL = os.environ["NOTIFICATION_QUEUE_URL"]

sqs = boto3.client("sqs")
app = FastAPI(title="notification-service", version="0.1.0")

_last_successful_poll = time.time()

REQUIRED_FIELDS = {"transaction_id", "from_account_id", "to_account_id", "amount", "currency"}


def _process_message(body: dict):
    missing = REQUIRED_FIELDS - body.keys()
    if missing:
        raise ValueError(f"message missing required fields: {missing}")

    amount_rupees = int(body["amount"]) / 100
    message = f"Transfer of {body['currency']} {amount_rupees:.2f} completed (transaction {body['transaction_id']})"

    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO notifications_log (transaction_id, channel, message) VALUES (%s, %s, %s)",
                (body["transaction_id"], "log", message),
            )
    finally:
        conn.close()

    log.info("notification sent: %s", message)


def consume_loop():
    global _last_successful_poll
    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=20,
                MessageAttributeNames=["All"],
            )
            messages = response.get("Messages", [])

            for msg in messages:
                receipt_handle = msg["ReceiptHandle"]
                try:
                    body = json.loads(msg["Body"])
                    if "Message" in body:
                        body = json.loads(body["Message"])
                    _process_message(body)
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)
                except Exception:
                    log.exception("failed to process message %s — leaving it for retry/DLQ", msg.get("MessageId"))

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


@app.get("/notifications/{transaction_id}")
def get_notifications(transaction_id: str):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, transaction_id, channel, message, sent_at FROM notifications_log WHERE transaction_id = %s",
                (transaction_id,),
            )
            rows = cur.fetchall()
            if not rows:
                raise HTTPException(status_code=404, detail="no notifications recorded for this transaction yet")
            return rows
    finally:
        conn.close()