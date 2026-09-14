"""
Pulls p95 CPU/memory usage per pod from CloudWatch Container Insights
(populated by the ADOT collector — see k8s/otel-fargate-container-insights.yaml)
over a trailing window, and recommends right-sized Fargate CPU/memory values
rounded to an actually-valid Fargate task size combination.

Metric names/namespace/dimensions used here come directly from the
metric_declarations block in the ADOT collector config this project deploys —
not guessed, matched exactly against what that config actually emits.

Usage:
    # First, get the current pod names for a service (they change every
    # deploy, so there's no way to hardcode these):
    kubectl get pods -n finledger -l app=transaction-service -o jsonpath='{.items[*].metadata.name}'

    python3 right_size_report.py \
        --service transaction-service \
        --pods transaction-service-abc123,transaction-service-def456 \
        --days 3 \
        --current-cpu-millicores 250 \
        --current-memory-mib 512

Requires AWS credentials with cloudwatch:GetMetricData, and at least a few
days of the pods above having actually been running and receiving traffic —
running this against a freshly-deployed pod with no real usage history
produces a right-sizing recommendation as meaningless as the defaults it's
replacing.
"""

import argparse
import boto3
from datetime import datetime, timedelta, timezone

CLUSTER_NAME = "finledger-cluster"
NAMESPACE = "ContainerInsights"
K8S_NAMESPACE = "finledger"

# Valid EKS Fargate vCPU/memory combinations as of this writing — verify
# against current AWS docs before relying on this list, since AWS has
# expanded this table over time and may again.
FARGATE_VALID_SIZES = [
    # (vcpu, memory_options_in_gib)
    (0.25, [0.5, 1, 2]),
    (0.5, list(range(1, 5))),
    (1, list(range(2, 9))),
    (2, list(range(4, 17))),
    (4, list(range(8, 31))),
]


def round_to_fargate_size(cpu_millicores: float, memory_mib: float):
    """Finds the smallest valid Fargate (vCPU, memory) combination that
    covers the requested amount, rather than an arbitrary number Fargate
    would silently round up anyway — being explicit about the real target
    size instead of relying on opaque rounding."""
    needed_vcpu = cpu_millicores / 1000
    needed_gib = memory_mib / 1024

    for vcpu, mem_options in FARGATE_VALID_SIZES:
        if vcpu >= needed_vcpu:
            for mem in mem_options:
                if mem >= needed_gib:
                    return vcpu, mem
    # Needed more than the largest table entry covers
    return None, None


def get_p95(cw_client, metric_name: str, pod_name: str, days: int) -> float:
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)

    response = cw_client.get_metric_statistics(
        Namespace=NAMESPACE,
        MetricName=metric_name,
        Dimensions=[
            {"Name": "ClusterName", "Value": CLUSTER_NAME},
            {"Name": "Namespace", "Value": K8S_NAMESPACE},
            {"Name": "PodName", "Value": pod_name},
        ],
        StartTime=start,
        EndTime=end,
        Period=300,  # 5-minute buckets
        ExtendedStatistics=["p95"],
    )

    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return None

    p95_values = [dp["ExtendedStatistics"]["p95"] for dp in datapoints]
    # The p95 OF the p95 datapoints is a reasonable conservative summary
    # across the whole window without needing raw-datapoint access.
    p95_values.sort()
    idx = int(len(p95_values) * 0.95)
    return p95_values[min(idx, len(p95_values) - 1)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", required=True)
    parser.add_argument("--pods", required=True, help="comma-separated pod names")
    parser.add_argument("--days", type=int, default=3)
    parser.add_argument("--current-cpu-millicores", type=float, required=True)
    parser.add_argument("--current-memory-mib", type=float, required=True)
    args = parser.parse_args()

    cw = boto3.client("cloudwatch")
    pod_names = [p.strip() for p in args.pods.split(",")]

    cpu_p95s = []
    mem_p95s = []

    for pod in pod_names:
        cpu = get_p95(cw, "pod_cpu_usage_total", pod, args.days)  # millicores
        mem_bytes = get_p95(cw, "pod_memory_working_set", pod, args.days)  # bytes

        if cpu is None or mem_bytes is None:
            print(f"WARNING: no data for pod {pod} — skipping (not enough history yet, or pod name is stale)")
            continue

        mem_mib = mem_bytes / (1024 * 1024)
        cpu_p95s.append(cpu)
        mem_p95s.append(mem_mib)
        print(f"  {pod}: p95 CPU = {cpu:.1f}m, p95 memory = {mem_mib:.1f}MiB")

    if not cpu_p95s:
        print("\nNo usable data across any pod — cannot make a recommendation. "
              "Check pod names are current and the ADOT collector has been running long enough.")
        return

    # Size for the worst-loaded replica observed, not the average — a
    # right-sizing recommendation that only covers the average replica would
    # under-provision whichever pod happens to take more traffic.
    worst_cpu = max(cpu_p95s)
    worst_mem = max(mem_p95s)

    # 20% headroom above the worst observed p95 — a deliberate safety margin,
    # not the raw p95 itself, since p95 by definition means 5% of samples
    # were higher than this.
    target_cpu = worst_cpu * 1.2
    target_mem = worst_mem * 1.2

    rec_vcpu, rec_mem_gib = round_to_fargate_size(target_cpu, target_mem)

    print(f"\n--- Recommendation for {args.service} ---")
    print(f"Current configured:  {args.current_cpu_millicores:.0f}m CPU / {args.current_memory_mib:.0f}MiB memory")
    print(f"Observed p95 (worst replica, over {args.days}d): {worst_cpu:.1f}m CPU / {worst_mem:.1f}MiB memory")
    print(f"Target (p95 + 20% headroom): {target_cpu:.1f}m CPU / {target_mem:.1f}MiB memory")
    if rec_vcpu is not None:
        rec_cpu_millicores = rec_vcpu * 1000
        rec_mem_mib = rec_mem_gib * 1024
        print(f"Recommended Fargate size: {rec_cpu_millicores:.0f}m CPU / {rec_mem_mib:.0f}MiB memory "
              f"({rec_vcpu} vCPU / {rec_mem_gib}GiB)")
        cpu_change_pct = (rec_cpu_millicores - args.current_cpu_millicores) / args.current_cpu_millicores * 100
        mem_change_pct = (rec_mem_mib - args.current_memory_mib) / args.current_memory_mib * 100
        print(f"Change vs. current: CPU {cpu_change_pct:+.0f}%, memory {mem_change_pct:+.0f}%")
    else:
        print("Target exceeds the largest Fargate size in this script's table — verify against current AWS limits.")


if __name__ == "__main__":
    main()