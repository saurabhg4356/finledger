import os
import psycopg
from psycopg.rows import dict_row


def get_connection():
    """
    A new connection per request is intentionally simple for this portfolio
    scale. At real production traffic this would move to a connection pool
    (e.g. psycopg.pool or PgBouncer) — worth naming as a known scaling limit
    rather than pretending it doesn't matter.
    """
    return psycopg.connect(
        host=os.environ.get("DB_HOST", "postgres"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "finledger"),
        user=os.environ.get("DB_USER", "finledger"),
        password=os.environ.get("DB_PASSWORD", "finledger_dev_password"),
        row_factory=dict_row,
    )