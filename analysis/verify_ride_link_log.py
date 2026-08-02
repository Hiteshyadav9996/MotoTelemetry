#!/usr/bin/env python3
"""Classify a ride_link_*.csv export against SoftAP stall success criteria.

Usage:
  python3 analysis/verify_ride_link_log.py path/to/ride_link.csv

Exit codes:
  0 = healthy / backpressure-working
  1 = unhealthy stalls (device_ms freeze without sse_skipped growth)
  2 = usage / parse error
"""

from __future__ import annotations

import csv
import sys
from collections import Counter
from pathlib import Path

# Success targets from the ride-stall plan.
MAX_HEALTHY_GAP_MS = 300
MAX_LIVE_PACKET_AGE_MS = 150
BURST_WARN = 5


def _int(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def classify_rows(rows: list[dict[str, str]]) -> dict:
    events = Counter(r.get("event", "") for r in rows)
    arrival_gaps = [
        g for r in rows if (g := _int(r.get("arrival_gap_ms"))) is not None
    ]
    device_gaps = [
        g for r in rows if (g := _int(r.get("device_gap_ms"))) is not None
    ]
    packet_ages = [
        g for r in rows if (g := _int(r.get("packet_age_ms"))) is not None
    ]

    max_arrival = max(arrival_gaps) if arrival_gaps else 0
    max_device = max(device_gaps) if device_gaps else 0
    max_age = max(packet_ages) if packet_ages else 0
    burst_events = events.get("burst", 0)
    degrade_enters = events.get("degrade_enter", 0)
    stale_reconnects = events.get("stale_reconnect", 0)
    demo_fallbacks = events.get("demo_fallback", 0)

    # Track whether sse_skipped rose across device_gap events (backpressure).
    skip_series = []
    for r in rows:
        skip = _int(r.get("sse_skipped"))
        if skip is not None:
            skip_series.append(skip)
    skip_rose = len(skip_series) >= 2 and skip_series[-1] > skip_series[0]

    large_device_gaps = [g for g in device_gaps if g > MAX_HEALTHY_GAP_MS]
    large_arrival_gaps = [g for g in arrival_gaps if g > MAX_HEALTHY_GAP_MS]

    # device_ms freeze without skip growth => true loop stall (old bug).
    true_loop_stall = bool(large_device_gaps) and not skip_rose
    # skips rose while gaps happened => backpressure working as designed.
    backpressure_working = bool(large_device_gaps or large_arrival_gaps) and skip_rose
    healthy = (
        max_arrival <= MAX_HEALTHY_GAP_MS
        and max_device <= MAX_HEALTHY_GAP_MS
        and burst_events <= BURST_WARN
        and demo_fallbacks == 0
        and (max_age == 0 or max_age <= MAX_LIVE_PACKET_AGE_MS * 20)
    )

    if true_loop_stall:
        verdict = "FAIL_LOOP_STALL"
    elif healthy:
        verdict = "PASS_HEALTHY"
    elif backpressure_working:
        verdict = "PASS_BACKPRESSURE"
    else:
        verdict = "WARN_SOFTAP_BLIPS"

    return {
        "verdict": verdict,
        "rows": len(rows),
        "events": dict(events),
        "max_arrival_gap_ms": max_arrival,
        "max_device_gap_ms": max_device,
        "max_packet_age_ms": max_age,
        "burst_events": burst_events,
        "degrade_enters": degrade_enters,
        "stale_reconnects": stale_reconnects,
        "demo_fallbacks": demo_fallbacks,
        "sse_skipped_rose": skip_rose,
        "true_loop_stall": true_loop_stall,
        "backpressure_working": backpressure_working,
        "healthy": healthy,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: verify_ride_link_log.py path/to/ride_link.csv", file=sys.stderr)
        return 2
    path = Path(argv[1])
    if not path.is_file():
        print(f"File not found: {path}", file=sys.stderr)
        return 2

    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)

    report = classify_rows(rows)
    print(f"file: {path}")
    print(f"verdict: {report['verdict']}")
    for key in (
        "rows",
        "max_arrival_gap_ms",
        "max_device_gap_ms",
        "max_packet_age_ms",
        "burst_events",
        "degrade_enters",
        "stale_reconnects",
        "demo_fallbacks",
        "sse_skipped_rose",
        "true_loop_stall",
        "backpressure_working",
        "healthy",
    ):
        print(f"{key}: {report[key]}")
    print(f"events: {report['events']}")

    if report["verdict"] == "FAIL_LOOP_STALL":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
