from uuid import UUID

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.database import get_connection

app = FastAPI(title="account-service", version="0.1.0")


class CreateAccountRequest(BaseModel):
    owner_name: str = Field(..., min_length=1)
    account_type: str = Field(default="user", pattern="^(user|system|fee|suspense)$")
    currency: str = Field(default="INR", min_length=3, max_length=3)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/accounts", status_code=201)
def create_account(req: CreateAccountRequest):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO accounts (owner_name, account_type, currency)
                VALUES (%s, %s, %s)
                RETURNING id, owner_name, account_type, currency, status, cached_balance, created_at
                """,
                (req.owner_name, req.account_type, req.currency),
            )
            return cur.fetchone()
    finally:
        conn.close()


@app.get("/accounts/{account_id}")
def get_account(account_id: UUID):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, owner_name, account_type, currency, status, cached_balance, created_at
                FROM accounts WHERE id = %s
                """,
                (str(account_id),),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="account not found")
            return row
    finally:
        conn.close()


@app.get("/accounts/{account_id}/balance")
def get_balance(account_id: UUID):
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT cached_balance, currency FROM accounts WHERE id = %s", (str(account_id),))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="account not found")
            return {"account_id": account_id, "balance": row["cached_balance"], "currency": row["currency"]}
    finally:
        conn.close()


@app.get("/accounts")
def list_accounts():
    conn = get_connection()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "SELECT id, owner_name, account_type, currency, status, cached_balance FROM accounts ORDER BY created_at"
            )
            return cur.fetchall()
    finally:
        conn.close()