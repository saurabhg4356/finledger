# Incident Postmortem Template

**Title:**
**Date:**
**Author:**
**Severity:** (Critical / High / Medium / Low)
**Status:** (Resolved / Monitoring / Investigating)

## Summary
One or two sentences: what happened, what was the user-facing impact.

## Impact
- Who/what was affected (which service, what fraction of requests)
- Duration of user-facing impact
- Any data integrity concern (and how it was ruled out or confirmed)

## Timeline
All timestamps in UTC. Include detection, not just the trigger — "when did we find out" is often the most revealing gap.

| Time | Event |
|---|---|
| | |

## Root Cause
What actually caused it, at the level of specificity that would let someone else prevent the same class of failure — not just "the database had an issue."

## Detection
How was this noticed? (Alert firing, manual observation, user report?) If detection was slower than it should have been, say so directly — that's often more actionable than the root cause itself.

## Resolution
What actually fixed it / what recovery looked like.

## Metrics
- **MTTD** (Mean Time To Detect): time from incident start to first detection
- **MTTR** (Mean Time To Resolve): time from detection to full resolution
- **RTO** (Recovery Time Objective, if applicable): actual recovery time achieved
- **RPO** (Recovery Point Objective, if applicable): actual data loss window, if any

## Action Items
| Action | Owner | Status |
|---|---|---|
| | | |

## What Went Well
Don't skip this section — it's not filler. Knowing what worked (an alert fired correctly, a design decision paid off) is exactly as useful as knowing what didn't, and it's the part most postmortem templates cut for time.