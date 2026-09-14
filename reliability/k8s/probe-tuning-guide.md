# Probe Tuning — What Changed and Why

## The problem with the Phase 5 probes

Every service's `readinessProbe`/`livenessProbe` used guessed values (`initialDelaySeconds: 5` or `15`) rather than anything measured. Two real failure modes come from this:

1. **`initialDelaySeconds` too short** → the liveness probe starts checking before the app has genuinely finished starting (DB connection pool warmup, first request compilation, etc.), sees failures, and kills+restarts a container that was never actually broken — a self-inflicted crash loop under any load or cold-start delay.
2. **`initialDelaySeconds` set generously "to be safe"** → a genuinely crashed container takes needlessly long to be detected and restarted, extending real downtime.

## The fix: measure, then use a `startupProbe`

**Step 1 — measure actual startup time**, don't guess:
```bash
kubectl logs -n finledger deployment/transaction-service --previous=false | head -5
# compare the pod's creation timestamp (kubectl get pod <name> -o jsonpath='{.status.startTime}')
# against the timestamp of the first "Uvicorn running on..." log line
```
Run this a few times, including once under simulated load, and take the worst-case observed startup time plus a safety margin.

**Step 2 — separate "is it still starting" from "is it alive"** using a `startupProbe`. This is the actual fix, not just a bigger number: while the `startupProbe` hasn't yet succeeded, Kubernetes disables the `livenessProbe` entirely — so a slow-starting container is never killed for being slow, but once started, the `livenessProbe`'s own timing can be tuned tight (fast detection of a genuine hang) without that tightness causing false-positive kills during startup.

### Worked example — `transaction-service` (apply the same pattern to every other service)

```yaml
          startupProbe:
            httpGet:
              path: /healthz
              port: 8003
            failureThreshold: 12    # 12 x 5s = 60s allowed to start — set from Step 1's measurement, not guessed
            periodSeconds: 5
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8003
            periodSeconds: 5        # tighter than Phase 5's 10s — traffic gets pulled from a struggling pod faster
            failureThreshold: 2     # 2 consecutive failures (10s) before removal from the Service's endpoints
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8003
            periodSeconds: 10
            failureThreshold: 3     # 30s of continuous failure before a restart — long enough to survive a brief GC pause or DB hiccup, short enough to actually recover from a real hang
```

Apply the equivalent block (with the right port) to `account-service`, `ledger-service`, `fraud-service`, and `notification-service`. `outbox-poller` already has a custom `/healthz` with its own staleness logic from Phase 6 — its `livenessProbe` timing is fine as-is since that endpoint already encodes "how stale is too stale," which is a stronger signal than a generic startup timer.

## Why `readinessProbe` and `livenessProbe` have DIFFERENT failure thresholds here

This is worth being able to explain directly: `readinessProbe` failing just means "stop sending this pod traffic" — a cheap, reversible, frequent action, so it's tuned to react fast (2 failures). `livenessProbe` failing means "kill and restart the container" — expensive and disruptive if wrong, so it's tuned to be more conservative (3 failures) to avoid restarting something that was only briefly slow. Using the same threshold for both is a common shortcut that trades away exactly this distinction.