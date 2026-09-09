import os
import psycopg
from psycopg.rows import dict_row


def get_connection():
    return psycopg.connect(
        host=os.environ.get("DB_HOST", "postgres"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "finledger"),
        user=os.environ.get("DB_USER", "finledger"),
        password=os.environ.get("DB_PASSWORD", "finledger_dev_password"),
        row_factory=dict_row,  # Replaces cursor_factory=RealDictCursor
    )