-- Phase 6 migration — run manually against the existing RDS instance:
--   psql "postgresql://<user>:<password>@<rds-endpoint>:5432/finledger" -f async.sql
--
-- Not added to db/init.sql because that file only runs on a container's FIRST
-- startup — a real RDS instance with existing data needs a real migration,
-- not a reseed. This is the honest way to evolve schema once a database
-- already has production-shaped data in it.

CREATE TABLE fraud_checks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id  UUID NOT NULL REFERENCES transactions(id),
    risk_score      INTEGER NOT NULL CHECK (risk_score BETWEEN 0 AND 100),
    flagged         BOOLEAN NOT NULL,
    reason          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE notifications_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id  UUID NOT NULL REFERENCES transactions(id),
    channel         TEXT NOT NULL DEFAULT 'log',
    message         TEXT NOT NULL,
    sent_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fraud_checks_transaction_id ON fraud_checks(transaction_id);
CREATE INDEX idx_notifications_log_transaction_id ON notifications_log(transaction_id);