-- FinLedger schema — matches Phase 1 design doc exactly.
-- Runs automatically on first Postgres container startup (docker-entrypoint-initdb.d).

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()

CREATE TABLE accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_name      TEXT NOT NULL,
    account_type    TEXT NOT NULL CHECK (account_type IN ('user', 'system', 'fee', 'suspense')),
    currency        CHAR(3) NOT NULL DEFAULT 'INR',
    status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'frozen', 'closed')),
    cached_balance  BIGINT NOT NULL DEFAULT 0,  -- minor units (paise)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE transactions (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key  TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'completed', 'failed')),
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('transfer', 'fee', 'reversal', 'genesis')),
    from_account_id  UUID REFERENCES accounts(id),
    to_account_id    UUID REFERENCES accounts(id),
    amount           BIGINT,
    currency         CHAR(3),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at     TIMESTAMPTZ
);

CREATE TABLE ledger_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id  UUID NOT NULL REFERENCES transactions(id),
    account_id      UUID NOT NULL REFERENCES accounts(id),
    entry_type      TEXT NOT NULL CHECK (entry_type IN ('debit', 'credit')),
    amount          BIGINT NOT NULL CHECK (amount > 0),
    currency        CHAR(3) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id  UUID NOT NULL REFERENCES transactions(id),
    event_type      TEXT NOT NULL,
    payload         JSONB NOT NULL,
    published       BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ledger_entries_account_id ON ledger_entries(account_id);
CREATE INDEX idx_ledger_entries_transaction_id ON ledger_entries(transaction_id);
CREATE INDEX idx_outbox_unpublished ON outbox_events(published) WHERE published = false;

-- Immutability at the DB level, not just app-level discipline.
-- (Local dev keeps this permissive since docker-compose runs everything as the
--  superuser by default; when this hits real infra in Phase 4, revoke UPDATE/DELETE
--  on ledger_entries from the app's IAM/DB role explicitly.)

-- Seed data: a system treasury account funds two demo user accounts via a
-- genesis transaction, so there's something to actually transfer in tests.
DO $$
DECLARE
    treasury_id UUID;
    alice_id UUID;
    bob_id UUID;
    genesis_txn_id UUID;
BEGIN
    INSERT INTO accounts (owner_name, account_type, cached_balance)
    VALUES ('System Treasury', 'system', 0) RETURNING id INTO treasury_id;

    INSERT INTO accounts (owner_name, account_type, cached_balance)
    VALUES ('Alice', 'user', 0) RETURNING id INTO alice_id;

    INSERT INTO accounts (owner_name, account_type, cached_balance)
    VALUES ('Bob', 'user', 0) RETURNING id INTO bob_id;

    INSERT INTO transactions (idempotency_key, status, transaction_type, from_account_id, to_account_id, amount, currency, completed_at)
    VALUES ('genesis-seed-alice-001', 'completed', 'genesis', treasury_id, alice_id, 1000000, 'INR', now())
    RETURNING id INTO genesis_txn_id;

    INSERT INTO ledger_entries (transaction_id, account_id, entry_type, amount, currency)
    VALUES
        (genesis_txn_id, treasury_id, 'debit', 1000000, 'INR'),
        (genesis_txn_id, alice_id, 'credit', 1000000, 'INR');

    UPDATE accounts SET cached_balance = cached_balance - 1000000 WHERE id = treasury_id;
    UPDATE accounts SET cached_balance = cached_balance + 1000000 WHERE id = alice_id;

    RAISE NOTICE 'Seeded treasury=%, alice=% (balance 10000.00 INR), bob=% (balance 0.00 INR)', treasury_id, alice_id, bob_id;
END $$;