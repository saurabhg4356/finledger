"""
Runs a tight polling loop against a target URL and logs every state
transition (up->down, down->up) with a timestamp, so a chaos experiment
produces an actual measured downtime duration instead of "it seemed fine."

Usage:
    kubectl port-forward -n finledger svc/transaction-service 8013:80
    python3 uptime_checker.py --url http://localhost:8013/healthz --interval 0.2

Run this in one terminal BEFORE starting a chaos experiment in another, and
leave it running through the whole experiment. Ctrl+C to stop; it prints a
summary of every downtime window observed.
"""

import argparse
import time
from datetime import datetime, timezone


import requests


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--interval", type=float, default=0.2, help="seconds between checks")
    parser.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()

    is_up = None
    down_since = None
    windows = []

    print(f"[{now_iso()}] starting uptime check against {args.url} every {args.interval}s")
    print("Ctrl+C to stop and print a summary.\n")

    try:
        while True:
            check_time = now_iso()
            try:
                resp = requests.get(args.url, timeout=args.timeout)
                healthy = resp.status_code == 200
            except requests.RequestException:
                healthy = False

            if is_up is None:
                is_up = healthy
                if not healthy:
                    # FIX: the very first observation can itself be a "down"
                    # state. Without this, down_since stays None and the
                    # first down->up transition crashes trying to parse it.
                    down_since = check_time
                print(f"[{check_time}] initial state: {'UP' if healthy else 'DOWN'}")
            elif healthy and not is_up:
                # transition: down -> up
                duration = (datetime.fromisoformat(check_time) - datetime.fromisoformat(down_since)).total_seconds()
                windows.append((down_since, check_time, duration))
                print(f"[{check_time}] RECOVERED — was down for {duration:.2f}s (since {down_since})")
                is_up = True
            elif not healthy and is_up:
                # transition: up -> down
                down_since = check_time
                print(f"[{check_time}] DOWN — starting downtime window")
                is_up = False

            time.sleep(args.interval)

    except KeyboardInterrupt:
        print("\n--- Summary ---")
        if not windows:
            print("No downtime observed during this run.")
        else:
            total = sum(w[2] for w in windows)
            print(f"{len(windows)} downtime window(s), total downtime: {total:.2f}s")
            for start, end, duration in windows:
                print(f"  {start} -> {end}  ({duration:.2f}s)")
        if not is_up:
            print("NOTE: still DOWN when stopped — the incident may not be fully resolved yet.")


if __name__ == "__main__":
    main()