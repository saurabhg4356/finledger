# ------------------------------------------------------------------------------
# A customer-managed key (CMK), replacing the AWS-managed default key Phase 4
# used. The practical difference: a CMK gives you your own key policy (who
# can use/administer it, independent of general IAM), your own rotation
# schedule, and every use of the key shows up in CloudTrail attributed to
# THIS key specifically — meaningfully better audit posture for a fintech
# ledger than "some AWS-managed key nobody has direct visibility into."
# ------------------------------------------------------------------------------
resource "aws_kms_key" "rds" {
  description             = "${var.project_name} RDS encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true # automatic annual rotation, AWS-managed rotation of the underlying key material
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.project_name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ------------------------------------------------------------------------------
# THE THING TO UNDERSTAND BEFORE TOUCHING YOUR EXISTING RDS INSTANCE:
#
# storage_encrypted and kms_key_id on aws_db_instance are ForceNew — Terraform
# CANNOT change encryption on a running instance in place. Adding
# kms_key_id = aws_kms_key.rds.arn to the existing Phase 4 aws_db_instance
# resource and running `terraform apply` will DESTROY and RECREATE the
# database, losing all current data unless you snapshot first.
#
# This is a genuinely common real-world question — "how do you encrypt an
# already-running unencrypted (or default-key-encrypted) RDS instance?" — and
# the honest answer is never "just change the setting": you snapshot, copy
# the snapshot WITH the new KMS key (snapshot copy is the one place you CAN
# change the key), restore a new instance from that copy, then cut traffic
# over and decommission the old one. The commands:
#
#   aws rds create-db-snapshot --db-instance-identifier finledger-postgres --db-snapshot-identifier finledger-pre-cmk-snapshot
#   aws rds copy-db-snapshot --source-db-snapshot-identifier finledger-pre-cmk-snapshot --target-db-snapshot-identifier finledger-cmk-snapshot --kms-key-id <alias/finledger-rds arn>
#   aws rds restore-db-instance-from-db-snapshot --db-instance-identifier finledger-postgres-cmk --db-snapshot-identifier finledger-cmk-snapshot
#
# Since this project's dev database is disposable seed data destroyed between
# sessions anyway (Phase 0's cost guardrails), the pragmatic path here is
# simpler: destroy and recreate via Terraform directly, accepting the data
# loss on a throwaway dev DB. State that trade-off explicitly if this comes
# up in an interview — the snapshot/restore path above is the real answer
# for anything with actual data in it.
# ------------------------------------------------------------------------------

output "rds_kms_key_arn" { value = aws_kms_key.rds.arn }
output "rds_kms_key_alias" { value = aws_kms_alias.rds.name }