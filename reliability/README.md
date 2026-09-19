# FinLedger — Phase 9: Reliability & Chaos

Everything since Phase 0 has been quietly building toward this phase — the metrics from Phase 7 are what you'll actually watch during these experiments, the idempotency design from Phase 2 is what makes the RDS failover safe, and the async decoupling from Phase 6 is exactly what Experiment 3 proves.

## A genuinely interesting Fargate fact this phase depends on

**EKS Fargate runs exactly one pod per node** — confirmed via search, not assumed. Each pod gets its own entry in `kubectl get nodes`. This means `kubectl drain <node>` is directly and literally applicable on Fargate, evicting exactly the one pod on that "node," respecting PodDisruptionBudgets via the real Eviction API — unlike `kubectl delete pod`, which bypasses PDB checks entirely since it doesn't go through eviction. That distinction is the actual mechanism behind Experiment 1's two parts, not a minor detail.

## Steps, in order

### 1. Apply the PDBs
```bash
kubectl apply -f k8s/pod-disruption-budgets.yaml
```
Note that `outbox-poller` deliberately has no PDB — see the comments in that file for why a PDB on a single-replica Deployment would actively make things worse, not better.

### 2. Tune the probes
Read `k8s/probe-tuning-guide.md`, measure real startup times per the method described, then apply the `startupProbe` pattern to every service's Deployment (transaction-service is fully worked out as the example). Redeploy through the existing CI pipeline.

### 3. Run all three chaos experiments
In order, since they build on each other conceptually even though they're independent to execute:
- `scripts/chaos-01-pod-kill-and-drain.md` — the PDB proof
- `scripts/chaos-02-rds-failover.md` — RTO/RPO measurement, requires `rds_multi_az=true`
- `scripts/chaos-03-fraud-service-down.md` — proves the Phase 6 decoupling actually works under real failure, not just in theory

Use `scripts/uptime_checker.py` for all three — it's what turns "seemed fine" into an actual measured number.

### 4. Write the real postmortem
`postmortems/TEMPLATE.md` is the reusable structure. `postmortems/2026-XX-XX-rds-failover-chaos-test.md` is a fully worked example — **read the honesty note at the top of that file first**: the narrative and structure are complete, but the specific timing numbers are explicit `[FILL IN]` placeholders, not fabricated results. Run Experiment 2 for real, then replace every placeholder with what you actually observed. That filled-in document — with your real numbers — is the single most valuable artifact this entire project produces for an interview.

## Why a postmortem beats every other artifact in this project

A working system with clean code proves you can build. A postmortem with real timestamps, a stated root cause, and honest action items proves you can operate what you built and think clearly under a failure you deliberately caused — closer to what a GCC interviewer is actually screening for than any amount of additional infrastructure would be. If you only have time to polish one thing before an interview, make it this document, filled in with your own real numbers from your own real experiments.

## Turn Multi-AZ back off when done
```bash
cd phase4-infrastructure/terraform
terraform apply -var="rds_multi_az=false"
```
Don't leave the doubled RDS cost running after Experiment 2 is complete.