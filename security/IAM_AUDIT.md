# FinLedger — IAM Least-Privilege Audit

A review of every IAM role created across Phases 0–8, checked against the principle each was supposed to follow: scoped to exactly what that identity needs, nothing account-wide unless the AWS API genuinely offers no narrower option.

| Role | Created in | Scope | Verdict |
|---|---|---|---|
| `finledger-auto-shutdown-lambda-role` | Phase 0 | 4 specific RDS actions + scoped CloudWatch Logs | **Pass.** Narrowly scoped from the start; no `AdministratorAccess` shortcut taken. |
| `finledger-github-actions-ci` | Phase 5 | ECR push/pull on named repos only, `eks:DescribeCluster` on one cluster ARN | **Pass**, with one addition this phase: `ecr:GetAuthorizationToken` still uses `Resource: "*"` because that specific action doesn't support resource-level scoping — verified this is a real AWS API limitation, not laziness. |
| `finledger-eks-fargate-pod-execution-role` | Phase 4 | AWS-managed `AmazonEKSFargatePodExecutionRolePolicy` | **Acceptable, not narrowed further.** This is the AWS-defined minimum for Fargate to pull images and write logs — there's no finer-grained managed alternative, and hand-rolling a replacement would just reconstruct the same policy with more maintenance burden for no real security gain. |
| `finledger-outbox-poller-role` | Phase 6 | `sns:Publish` on exactly one topic ARN | **Pass.** Textbook least privilege. |
| `finledger-fraud-service-role` | Phase 6 | Receive/Delete/GetAttributes on exactly one SQS queue ARN | **Pass.** Cannot touch the notification queue or any DLQ directly. |
| `finledger-notification-service-role` | Phase 6 | Same shape as fraud-service, scoped to its own queue | **Pass.** |
| `finledger-cloudwatch-exporter-role` | Phase 7 | `cloudwatch:List/GetMetricData/GetMetricStatistics` + `tag:GetResources`, all `Resource: "*"` | **Acceptable, flagged not silently accepted.** CloudWatch's read APIs genuinely don't support resource-level ARN scoping — this is as narrow as this specific set of permissions can get. Worth being able to say that explicitly in an interview rather than claim false precision. |
| `finledger-external-secrets-role` | Phase 8 | `GetSecretValue`/`DescribeSecret` on exactly 2 secret ARNs | **Pass.** Cannot read any other secret in the account, including ones from unrelated future projects sharing this AWS account. |
| `finledger-alb-controller-role` | Phase 8 | Official upstream policy (EC2/ELB/WAF describe+manage), largely `Resource: "*"` | **Accepted as-is, not weakened further.** This is AWS's own published policy for this controller — several statements are scoped by `aws:ResourceTag/elbv2.k8s.aws/cluster` conditions rather than ARNs, which is the pattern the controller's design requires (it manages resources it creates, identified by tag, not by a fixed ARN list known in advance). Hand-editing this policy risks breaking the controller in ways that are hard to diagnose; the tag-based conditions are the actual scoping mechanism here, not `Resource: "*"` alone. |

## Two things worth doing that this project has NOT done

**1. No IAM Access Analyzer enabled.** AWS's own tool for finding overly-permissive policies and unused permissions has not been turned on for this account. This is a five-minute, zero-cost enablement (`aws accessanalyzer create-analyzer`) that would catch drift in this audit automatically going forward rather than relying on a manual review like this one. Worth doing before calling IAM work "complete."

**2. No periodic unused-permission review.** Every role above was scoped correctly *at creation time*, but permissions tend to accumulate as a project evolves and nobody goes back to remove what's no longer used. IAM Access Analyzer's "unused access" findings (or a scheduled `aws iam generate-service-last-accessed-details` check) is the honest way to catch this over time — not implemented here, named as a gap rather than silently skipped.

## Why this audit is a written document, not just fixed code

Most of the roles in this project were already reasonably scoped as they were built — the discipline was applied incrementally, phase by phase, rather than needing a big cleanup now. What this document adds is the thing that discipline alone doesn't produce: a legible record of *why* each scope is what it is, including the two cases (`ecr:GetAuthorizationToken`, CloudWatch reads) where `Resource: "*"` is the correct answer, not a shortcut. "How do you know your IAM is least-privilege" is a much stronger interview answer with this document to point to than "I think I was careful."