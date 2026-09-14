/*
Simulates transfer bursts against transaction-service, ramping request rate
up in stages to find the actual breaking point rather than testing a single
fixed load level.

Prerequisite: scripts/seed_load_test_accounts.sql must have been run —
this script picks random pairs from the 100 loadtest-* accounts it creates,
specifically to avoid every request contending for the same two rows'
FOR UPDATE locks (see that file's comments for why that would invalidate
the whole test).

Run with:
    k6 run --out json=results/raw-run-$(date +%s).json transfer_burst.js

Point it at the service directly (via kubectl port-forward) rather than the
public ALB for this test — you want to measure the service's own breaking
point, not conflate it with WAF rate-limiting from Phase 8, which has its
own, separate, deliberately low threshold (100 req/5min on this exact
endpoint) that would make the test hit an artificial ceiling that has
nothing to do with the service's actual capacity.
    kubectl port-forward -n finledger svc/transaction-service 8013:80
    kubectl port-forward -n finledger svc/account-service 8011:80
*/

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const ACCOUNT_SERVICE = __ENV.ACCOUNT_SERVICE_URL || 'http://localhost:8011';
const TRANSACTION_SERVICE = __ENV.TRANSACTION_SERVICE_URL || 'http://localhost:8013';

const insufficientFundsErrors = new Counter('insufficient_funds_errors');
const serverErrors = new Counter('server_errors');
const transferLatency = new Trend('transfer_latency', true);

// Loaded once at test start (setup()), shared read-only across all VUs —
// avoids every VU independently hitting account-service just to build its
// own account list.
const accounts = new SharedArray('loadtest accounts', function () {
  const res = http.get(`${ACCOUNT_SERVICE}/accounts`);
  const all = JSON.parse(res.body);
  const loadtestAccounts = all.filter((a) => a.owner_name.startsWith('loadtest-'));
  if (loadtestAccounts.length < 10) {
    throw new Error(
      `Only found ${loadtestAccounts.length} loadtest-* accounts — did you run seed_load_test_accounts.sql first?`
    );
  }
  return loadtestAccounts;
});

export const options = {
  scenarios: {
    breaking_point_search: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 500, // ceiling on k6's own resource usage — raise this if k6 itself becomes the bottleneck before the app does
      stages: [
        { target: 10, duration: '1m' },   // baseline
        { target: 30, duration: '2m' },
        { target: 60, duration: '2m' },
        { target: 100, duration: '2m' },
        { target: 150, duration: '2m' },
        { target: 200, duration: '2m' },
        { target: 300, duration: '2m' },  // if the system survives this, raise the ceiling further and re-run
        { target: 0, duration: '1m' },    // ramp down — see the recovery shape, not just the failure
      ],
    },
  },
  thresholds: {
    // Deliberately NOT set to auto-abort the test on high error rates — the
    // whole point is to keep running THROUGH the breaking point and observe
    // what it looks like, not stop the moment things start failing.
    http_req_duration: ['p(95)<5000'], // informational threshold, not a hard abort
  },
};

export default function () {
  // Pick two distinct random accounts — this is what spreads FOR UPDATE
  // lock contention across 100 different row pairs instead of hammering one.
  const fromIdx = Math.floor(Math.random() * accounts.length);
  let toIdx = Math.floor(Math.random() * accounts.length);
  while (toIdx === fromIdx) {
    toIdx = Math.floor(Math.random() * accounts.length);
  }

  const payload = JSON.stringify({
    idempotency_key: `k6-${__VU}-${__ITER}-${Date.now()}`,
    from_account_id: accounts[fromIdx].id,
    to_account_id: accounts[toIdx].id,
    amount: 1000, // ₹10 — small relative to each account's ₹100,000 seed funding, so accounts don't run dry mid-test
    currency: 'INR',
  });

  const res = http.post(`${TRANSACTION_SERVICE}/transactions/transfer`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '10s',
  });

  transferLatency.add(res.timings.duration);

  const ok = check(res, {
    'status is 201': (r) => r.status === 201,
  });

  if (!ok) {
    if (res.status === 422) {
      insufficientFundsErrors.add(1); // expected occasionally as accounts deplete over a long run — not itself evidence of a breaking point
    } else {
      serverErrors.add(1); // 5xx, timeouts, connection refused — THIS is what you're actually hunting for
    }
  }
}