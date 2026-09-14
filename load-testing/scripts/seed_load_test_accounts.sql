apiVersion: v1
kind: ConfigMap
metadata:
  name: loadtest-seed-sql
  namespace: finledger
data:
  seed.sql: |
    DO $$
    DECLARE
        treasury_id UUID;
        new_account_id UUID;
        genesis_txn_id UUID;
        i INT;
    BEGIN
        SELECT id INTO treasury_id FROM accounts WHERE owner_name = 'System Treasury';

        FOR i IN 1..100 LOOP
            INSERT INTO accounts (owner_name, account_type, cached_balance)
            VALUES ('loadtest-' || i, 'user', 0)
            RETURNING id INTO new_account_id;

            INSERT INTO transactions (idempotency_key, status, transaction_type, from_account_id, to_account_id, amount, currency, completed_at)
            VALUES ('genesis-seed-loadtest-' || i, 'completed', 'genesis', treasury_id, new_account_id, 10000000, 'INR', now())
            RETURNING id INTO genesis_txn_id;

            INSERT INTO ledger_entries (transaction_id, account_id, entry_type, amount, currency)
            VALUES
                (genesis_txn_id, treasury_id, 'debit', 10000000, 'INR'),
                (genesis_txn_id, new_account_id, 'credit', 10000000, 'INR');

            UPDATE accounts SET cached_balance = cached_balance - 10000000 WHERE id = treasury_id;
            UPDATE accounts SET cached_balance = cached_balance + 10000000 WHERE id = new_account_id;
        END LOOP;

        RAISE NOTICE 'Seeded 100 load-test accounts, each funded with 100000.00 INR';
    END $$;
---
apiVersion: batch/v1
kind: Job
metadata:
  name: seed-loadtest-accounts
  namespace: finledger
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: seed
          image: postgres:16-alpine
          envFrom:
            - secretRef:
                name: finledger-db-credentials
          command: ["sh", "-c"]
          args:
            - |
              PGPASSWORD="$DB_PASSWORD" psql \
                -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
                -v ON_ERROR_STOP=1 \
                -f /seed/seed.sql
          volumeMounts:
            - name: seed-sql
              mountPath: /seed
              readOnly: true
      volumes:
        - name: seed-sql
          configMap:
            name: loadtest-seed-sql