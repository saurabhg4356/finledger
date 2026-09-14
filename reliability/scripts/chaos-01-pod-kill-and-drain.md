# Chaos Experiment 1 — Pod Kill & Node Drain

## Part A: single pod kill (baseline — should show ~zero downtime)

```bash
# Terminal 1
kubectl port-forward -n finledger svc/transaction-service 8013:80
python3 scripts/uptime_checker.py --url http://localhost:8013/healthz --interval 0.2

# Terminal 2 — kill one of the two replicas directly
kubectl get pods -n finledger -l app=transaction-service
kubectl delete pod <one-of-the-two-pod-names> -n finledger
```

**Expected result:** zero or near-zero downtime in the checker's summary. The Service has two endpoints; removing one still leaves the other serving, and `kubectl delete pod` triggers the Deployment controller to schedule a replacement immediately. This baseline is what "replicas=2 is enough for a single pod loss" actually looks like measured, not assumed.

## Part B: the real PDB proof — drain both replicas back-to-back

This is the experiment that actually demonstrates what a PodDisruptionBudget does, which Part A does not — a single pod loss with 2 replicas succeeds whether or not a PDB exists.

Recall from this phase's research: **EKS Fargate runs exactly one pod per node** — each pod gets its own entry in `kubectl get nodes`. That makes `kubectl drain` directly applicable here, not just an EC2-nodegroup concept.

```bash
# Identify the two Fargate "nodes" (one per transaction-service pod)
kubectl get pods -n finledger -l app=transaction-service -o wide
# note the NODE column for both pods — call them NODE_A and NODE_B

# Start the uptime checker (as in Part A) before proceeding

# Drain the first one — this SHOULD succeed
kubectl drain NODE_A --ignore-daemonsets --delete-emptydir-data

# Immediately, before NODE_A's replacement pod is Ready, try to drain the second
kubectl drain NODE_B --ignore-daemonsets --delete-emptydir-data
```

**Expected result:** the second `kubectl drain` **blocks/hangs** with output like `error when evicting pod ... Cannot evict pod as it would violate the pod's disruption budget.` — it will keep retrying until NODE_A's replacement becomes Ready and satisfies `minAvailable: 1` on `transaction-service-pdb`, at which point it proceeds.

**Now repeat this same sequence with the PDB deleted** (`kubectl delete pdb transaction-service-pdb -n finledger`) to see the contrast: both drains succeed immediately back-to-back, and the uptime checker should show a real downtime window this time — this is what the PDB was silently preventing. Re-apply the PDB afterward.

## What to record for the postmortem
- Part A: downtime duration (expect ~0s)
- Part B with PDB: whether the second drain blocked, and for how long
- Part B without PDB: measured downtime duration when both replicas were evicted close together