"""
The other half of the Outbox Pattern from the Phase 1 design doc.
transaction-service writes outbox_events rows in the SAME DB transaction as
the ledger entries. This poller is the separate process that reads those rows
and actually gets them onto SNS — turning "an event was recorded" into
"an event was delivered" without ever risking the dual-write problem the
pattern exists to avoid.
"""

import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
import psycopg
from psycopg.rows import dict_row

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("outbox-poller")

POLL_INTERVAL_SECONDS = float(os.environ.get("POLL_INTERVAL_SECONDS", "2"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "20"))
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

sns = boto3.client("sns")

_last_successful_poll = time.time()


class _HealthzHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Liveness signal: unhealthy if the poll loop hasn't completed in
        # over 60s (5x the default 2s interval, minus normal jitter) — a
        # stuck DB connection or a crashed loop shows up here instead of
        # silently never publishing anything again.
        healthy = (time.time() - _last_successful_poll) < 60
        self.send_response(200 if healthy else 503)
        self.end_headers()
        self.wfile.write(b"ok" if healthy else b"stale")

    def log_message(self, *args):
        pass  # silence default request logging — this fires every few seconds from the probe


def _start_healthz_server():
    HTTPServer(("0.0.0.0", 8080), _HealthzHandler).serve_forever()


def get_connection():
    return psycopg.connect(
        host=os.environ.get("DB_HOST", "postgres"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "finledger"),
        user=os.environ.get("DB_USER", "finledger"),
        password=os.environ.get("DB_PASSWORD", "finledger_dev_password"),
        row_factory=dict_row,
    )


def poll_once():
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            # FOR UPDATE SKIP LOCKED matters the moment this poller is scaled
            # to more than one replica: without it, two poller instances would
            # both grab the same unpublished rows and double-publish every
            # event. SKIP LOCKED means each replica only ever picks up rows
            # nobody else currently has locked — safe horizontal scaling with
            # zero coordination logic required.
            cur.execute(
                """
                SELECT id, transaction_id, event_type, payload
                FROM outbox_events
                WHERE published = false
                ORDER BY created_at
                LIMIT %s
                FOR UPDATE SKIP LOCKED
                """,
                (BATCH_SIZE,),
            )
            rows = cur.fetchall()

            for row in rows:
                try:
                    sns.publish(
                        TopicArn=SNS_TOPIC_ARN,
                        Message=json.dumps(row["payload"]),
                        MessageAttributes={
                            "event_type": {"DataType": "String", "StringValue": row["event_type"]},
                        },
                    )
                    cur.execute("UPDATE outbox_events SET published = true WHERE id = %s", (row["id"],))
                    log.info("published outbox event %s (transaction %s)", row["id"], row["transaction_id"])
                except Exception:
                    # Deliberately don't mark this row published, and don't let
                    # one bad row abort the whole batch — the transaction
                    # commits what succeeded; this row gets retried next poll.
                    log.exception("failed to publish outbox event %s, will retry", row["id"])
    finally:
        conn.close()


def main():
    log.info("outbox-poller starting, polling every %ss", POLL_INTERVAL_SECONDS)
    threading.Thread(target=_start_healthz_server, daemon=True).start()

    global _last_successful_poll
    while True:
        try:
            poll_once()
            _last_successful_poll = time.time()
        except Exception:
            log.exception("poll_once() failed entirely, will retry after interval")
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()