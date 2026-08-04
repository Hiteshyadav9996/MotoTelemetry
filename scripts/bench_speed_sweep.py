#!/usr/bin/env python3
"""Laptop-driven Dominar 400 cluster speedometer bench sweep.

Connect the laptop to the ESP32 AP (`D400Telemetry`), keep the odometer/cluster
on the isolated bench bus, then run this script. It sends one candidate speed
encoding at a time and asks you to type what the cluster displayed.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


DEFAULT_HOST = "http://192.168.4.1"
DEFAULT_SPEEDS = [0, 5, 10, 20, 30, 40, 50, 60, 80, 100, 120, 140, 160]
CONFIRM_SPEEDS = list(range(0, 161, 10))


@dataclass(frozen=True)
class Candidate:
    name: str
    description: str
    can_id: str
    byte_indexes: tuple[int, ...]
    encoding: str
    scale: float = 1.0
    offset: int = 0
    companion_b302: bool = True


def candidates() -> list[Candidate]:
    return [
        Candidate("patch_30c_b01_be_x1", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h", "0x30C", (0, 1), "u16be_mul", 1.0),
        Candidate("patch_30c_b01_be_x10", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*10", "0x30C", (0, 1), "u16be_mul", 10.0),
        Candidate("patch_30c_b01_be_x20", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*20", "0x30C", (0, 1), "u16be_mul", 20.0),
        Candidate("patch_30c_b01_be_x25", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*25", "0x30C", (0, 1), "u16be_mul", 25.0),
        Candidate("patch_30c_b01_be_x40", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*40", "0x30C", (0, 1), "u16be_mul", 40.0),
        Candidate("patch_30c_b01_be_x50", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*50", "0x30C", (0, 1), "u16be_mul", 50.0),
        Candidate("patch_30c_b01_be_x100", "Wheel capture candidate: 0x30C b0,b1 big-endian, raw=km/h*100", "0x30C", (0, 1), "u16be_mul", 100.0),
        Candidate("patch_30c_b01_be_x116", "Focused 0x30C b0,b1 big-endian: raw=km/h*116", "0x30C", (0, 1), "u16be_mul", 116.0),
        Candidate("patch_30c_b01_be_x117", "Focused 0x30C b0,b1 big-endian: raw=km/h*117", "0x30C", (0, 1), "u16be_mul", 117.0),
        Candidate("patch_30c_b01_be_x118", "Focused 0x30C b0,b1 big-endian: raw=km/h*118", "0x30C", (0, 1), "u16be_mul", 118.0),
        Candidate("patch_30c_b01_be_x118p37", "Focused 0x30C b0,b1 big-endian: raw=km/h*118.37", "0x30C", (0, 1), "u16be_mul", 118.37),
        Candidate("patch_30c_b01_be_x119", "Focused 0x30C b0,b1 big-endian: raw=km/h*119", "0x30C", (0, 1), "u16be_mul", 119.0),
        Candidate("patch_30c_b01_be_x120", "Focused 0x30C b0,b1 big-endian: raw=km/h*120", "0x30C", (0, 1), "u16be_mul", 120.0),
        Candidate("patch_30c_b01_le_x20", "Wheel capture candidate: 0x30C b0,b1 little-endian, raw=km/h*20", "0x30C", (0, 1), "u16le_mul", 20.0),
        Candidate("patch_30c_b0_x1", "Wheel capture candidate: 0x30C b0 as high-byte speed bucket", "0x30C", (0,), "u8_mul", 1.0),
        Candidate("patch_30c_b1_x1", "Wheel capture candidate: 0x30C b1 as low-byte speed bucket", "0x30C", (1,), "u8_mul", 1.0),
        Candidate("patch_540_b3_x1", "0x540 b3 as one-byte speed: raw=km/h", "0x540", (3,), "u8_mul", 1.0),
        Candidate("patch_540_b3_x2", "0x540 b3 as one-byte speed: raw=km/h*2", "0x540", (3,), "u8_mul", 2.0),
        Candidate("patch_540_b3_x10", "0x540 b3 as low-speed byte: raw=km/h*10", "0x540", (3,), "u8_mul", 10.0),
        Candidate("patch_542_b01_be_x1", "0x542 b0,b1 big-endian: raw=km/h", "0x542", (0, 1), "u16be_mul", 1.0),
        Candidate("patch_542_b01_be_x10", "0x542 b0,b1 big-endian: raw=km/h*10", "0x542", (0, 1), "u16be_mul", 10.0),
        Candidate("patch_542_b01_be_x100", "0x542 b0,b1 big-endian: raw=km/h*100", "0x542", (0, 1), "u16be_mul", 100.0),
        Candidate("patch_542_b01_le_x10", "0x542 b0,b1 little-endian: raw=km/h*10", "0x542", (0, 1), "u16le_mul", 10.0),
        Candidate("patch_542_b01_be_8000_x10", "0x542 b0,b1 big-endian centered at 0x8000: raw=0x8000+km/h*10", "0x542", (0, 1), "u16be_mul", 10.0, 0x8000),
        Candidate("patch_542_b01_be_8000_x100", "0x542 b0,b1 big-endian centered at 0x8000: raw=0x8000+km/h*100", "0x542", (0, 1), "u16be_mul", 100.0, 0x8000),
        Candidate("patch_542_b45_be_x1", "0x542 b4,b5 big-endian: raw=km/h", "0x542", (4, 5), "u16be_mul", 1.0),
        Candidate("patch_542_b45_be_x10", "0x542 b4,b5 big-endian: raw=km/h*10", "0x542", (4, 5), "u16be_mul", 10.0),
        Candidate("patch_542_b45_be_x100", "0x542 b4,b5 big-endian: raw=km/h*100", "0x542", (4, 5), "u16be_mul", 100.0),
        Candidate("patch_542_b45_le_x10", "0x542 b4,b5 little-endian: raw=km/h*10", "0x542", (4, 5), "u16le_mul", 10.0),
        Candidate("patch_542_b45_be_8000_x10", "0x542 b4,b5 big-endian centered at 0x8000: raw=0x8000+km/h*10", "0x542", (4, 5), "u16be_mul", 10.0, 0x8000),
        Candidate("patch_542_b45_be_8000_x100", "0x542 b4,b5 big-endian centered at 0x8000: raw=0x8000+km/h*100", "0x542", (4, 5), "u16be_mul", 100.0, 0x8000),
        Candidate("patch_303_b1_x1", "0x303 b1 as one-byte speed: raw=km/h", "0x303", (1,), "u8_mul", 1.0),
        Candidate("patch_303_b2_x1", "0x303 b2 as one-byte speed: raw=km/h", "0x303", (2,), "u8_mul", 1.0),
        Candidate("patch_303_b3_x1", "0x303 b3 as one-byte speed: raw=km/h", "0x303", (3,), "u8_mul", 1.0),
        Candidate("patch_303_b23_repeat_x1", "0x303 b2,b3 duplicated as one-byte speed: raw=km/h", "0x303", (2, 3), "repeat_u8_mul", 1.0),
        Candidate("patch_303_b23_be_x1", "0x303 b2,b3 big-endian: raw=km/h", "0x303", (2, 3), "u16be_mul", 1.0),
        Candidate("patch_303_b23_be_x10", "0x303 b2,b3 big-endian: raw=km/h*10", "0x303", (2, 3), "u16be_mul", 10.0),
        Candidate("patch_304_b0_x1", "0x304 b0 as one-byte speed/status: raw=km/h", "0x304", (0,), "u8_mul", 1.0),
        Candidate("patch_304_b0_x2", "0x304 b0 as one-byte speed/status: raw=km/h*2", "0x304", (0,), "u8_mul", 2.0),
        Candidate("patch_310_b2_x1", "0x310 b2 as one-byte speed candidate: raw=km/h", "0x310", (2,), "u8_mul", 1.0),
        Candidate("patch_310_b2_x2", "0x310 b2 as one-byte speed candidate: raw=km/h*2", "0x310", (2,), "u8_mul", 2.0),
        Candidate("patch_311_b01_be_x1", "0x311 b0,b1 big-endian: raw=km/h", "0x311", (0, 1), "u16be_mul", 1.0),
        Candidate("patch_311_b01_be_x10", "0x311 b0,b1 big-endian: raw=km/h*10", "0x311", (0, 1), "u16be_mul", 10.0),
        Candidate("patch_311_b23_be_x1", "0x311 b2,b3 big-endian: raw=km/h", "0x311", (2, 3), "u16be_mul", 1.0),
        Candidate("patch_311_b23_be_x10", "0x311 b2,b3 big-endian: raw=km/h*10", "0x311", (2, 3), "u16be_mul", 10.0),
        Candidate("patch_315_b2_x1", "0x315 b2 as one-byte speed/status: raw=km/h", "0x315", (2,), "u8_mul", 1.0),
        Candidate("patch_315_b2_x2", "0x315 b2 as one-byte speed/status: raw=km/h*2", "0x315", (2,), "u8_mul", 2.0),
        Candidate("patch_316_b4_x1", "0x316 b4 as one-byte speed/status: raw=km/h", "0x316", (4,), "u8_mul", 1.0),
        Candidate("patch_316_b4_x2", "0x316 b4 as one-byte speed/status: raw=km/h*2", "0x316", (4,), "u8_mul", 2.0),
        Candidate("patch_317_b0_x1", "0x317 b0 as one-byte speed/status: raw=km/h", "0x317", (0,), "u8_mul", 1.0),
        Candidate("patch_317_b0_x2", "0x317 b0 as one-byte speed/status: raw=km/h*2", "0x317", (0,), "u8_mul", 2.0),
        Candidate("patch_447_b23_be_x1", "0x447 b2,b3 big-endian: raw=km/h", "0x447", (2, 3), "u16be_mul", 1.0),
        Candidate("patch_447_b23_be_x10", "0x447 b2,b3 big-endian: raw=km/h*10", "0x447", (2, 3), "u16be_mul", 10.0),
        Candidate("patch_448_b56_be_x1", "0x448 b5,b6 big-endian: raw=km/h", "0x448", (5, 6), "u16be_mul", 1.0),
        Candidate("patch_448_b56_be_x10", "0x448 b5,b6 big-endian: raw=km/h*10", "0x448", (5, 6), "u16be_mul", 10.0),
        Candidate("patch_500_b0_x1", "0x500 b0 as one-byte speed candidate: raw=km/h", "0x500", (0,), "u8_mul", 1.0),
        Candidate("patch_500_b1_x1", "0x500 b1 as one-byte speed candidate: raw=km/h", "0x500", (1,), "u8_mul", 1.0),
        Candidate("patch_500_b01_be_x10", "0x500 b0,b1 big-endian: raw=km/h*10", "0x500", (0, 1), "u16be_mul", 10.0),
    ]


PLAN_NAMES = {
    "fast": [
        "patch_30c_b01_be_x10",
        "patch_30c_b01_be_x20",
        "patch_30c_b01_be_x25",
        "patch_30c_b01_be_x40",
        "patch_30c_b01_be_x50",
        "patch_30c_b01_be_x100",
        "patch_540_b3_x1",
        "patch_540_b3_x2",
        "patch_542_b01_be_8000_x10",
        "patch_542_b01_be_8000_x100",
        "patch_542_b45_be_8000_x10",
        "patch_542_b45_be_8000_x100",
        "patch_303_b23_repeat_x1",
        "patch_304_b0_x1",
        "patch_447_b23_be_x10",
        "patch_448_b56_be_x10",
        "patch_500_b0_x1",
        "patch_500_b01_be_x10",
    ],
    "confirm30c": [
        "patch_30c_b01_be_x116",
        "patch_30c_b01_be_x117",
        "patch_30c_b01_be_x118",
        "patch_30c_b01_be_x118p37",
        "patch_30c_b01_be_x119",
        "patch_30c_b01_be_x120",
    ],
    "full": [candidate.name for candidate in candidates()],
}


def round_half_up(value: float) -> int:
    return int(math.floor(value + 0.5))


def parse_values(value: str) -> list[int]:
    out: list[int] = []
    for token in value.replace(";", ",").replace(" ", ",").split(","):
        token = token.strip()
        if not token:
            continue
        speed = int(token)
        if speed < 0:
            raise ValueError(f"bad speed {speed}")
        out.append(speed)
    if not out:
        raise ValueError("empty speed list")
    return out


def parse_range(value: str) -> list[int]:
    parts = [part.strip() for part in value.split(":")]
    if len(parts) not in {2, 3} or any(not part for part in parts):
        raise ValueError("range must be start:end or start:end:step")
    start = int(parts[0])
    end = int(parts[1])
    step = int(parts[2]) if len(parts) == 3 else 10
    if start < 0 or end < 0 or step <= 0:
        raise ValueError("range values must be non-negative and step must be positive")
    if start > end:
        raise ValueError("range start must be <= end")
    return list(range(start, end + 1, step))


def encode_bytes(candidate: Candidate, speed_kph: int) -> tuple[bytes | None, str]:
    raw = round_half_up(candidate.offset + speed_kph * candidate.scale)
    offset_note = "" if candidate.offset == 0 else f" offset=0x{candidate.offset:04X}"

    if candidate.encoding == "u8_mul":
        if raw < 0 or raw > 0xFF:
            return None, f"raw {raw} outside u8"
        return bytes([raw]), f"raw={raw} 0x{raw:02X} scale={candidate.scale:g}{offset_note}"

    if candidate.encoding == "repeat_u8_mul":
        if raw < 0 or raw > 0xFF:
            return None, f"raw {raw} outside u8"
        return bytes([raw] * len(candidate.byte_indexes)), f"raw={raw} 0x{raw:02X} repeated scale={candidate.scale:g}{offset_note}"

    if candidate.encoding == "u16be_mul":
        if raw < 0 or raw > 0xFFFF:
            return None, f"raw {raw} outside u16"
        return bytes([(raw >> 8) & 0xFF, raw & 0xFF]), f"raw={raw} 0x{raw:04X} be scale={candidate.scale:g}{offset_note}"

    if candidate.encoding == "u16le_mul":
        if raw < 0 or raw > 0xFFFF:
            return None, f"raw {raw} outside u16"
        return bytes([raw & 0xFF, (raw >> 8) & 0xFF]), f"raw={raw} 0x{raw:04X} le scale={candidate.scale:g}{offset_note}"

    raise ValueError(f"unknown encoding {candidate.encoding}")


def build_url(host: str, candidate: Candidate, speed_kph: int, profile: str) -> tuple[str | None, str]:
    payload, raw_note = encode_bytes(candidate, speed_kph)
    if payload is None:
        return None, raw_note

    query = {
        "id": candidate.can_id,
        "bytes": ",".join(str(index) for index in candidate.byte_indexes),
        "values": payload.hex().upper(),
        "profile": profile,
    }
    if candidate.companion_b302:
        query["b302"] = "1,3,7"
    return f"{host.rstrip('/')}/bench/patch?{urllib.parse.urlencode(query)}", raw_note


def fetch_json(url: str, timeout: float) -> dict[str, object]:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        body = response.read().decode("utf-8", errors="replace")
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {"ok": False, "raw_response": body}
    return parsed if isinstance(parsed, dict) else {"ok": False, "response": parsed}


def restore_baseline(host: str, mode: str, timeout: float, settle: float) -> dict[str, object]:
    query = urllib.parse.urlencode({"mode": mode})
    url = f"{host.rstrip('/')}/bench/profile?{query}"
    print(f"Restoring clean baseline: {url}")
    response = fetch_json(url, timeout)
    if not response.get("ok", False):
        print(f"Baseline restore response not ok: {response}")
    time.sleep(settle)
    return response


def parse_observed(value: str) -> float | None:
    value = value.strip().lower()
    if not value or value in {"s", "skip", "n", "na", "-"}:
        return None
    return float(value)


def is_can_failure_answer(value: str) -> bool:
    return value.strip().lower() in {
        "fail",
        "canfail",
        "can",
        "s-can",
        "scan",
        "s can",
        "error",
        "err",
        "blink",
        "blinking",
    }


def write_row(path: Path, row: dict[str, object], fieldnames: list[str]) -> None:
    exists = path.exists()
    with path.open("a", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        if not exists:
            writer.writeheader()
        writer.writerow(row)


def summarize(rows: list[dict[str, object]], tolerance: float) -> list[dict[str, object]]:
    by_candidate: dict[str, list[dict[str, object]]] = {}
    for row in rows:
        if row.get("observed_kph") in {"", None}:
            continue
        by_candidate.setdefault(str(row["candidate"]), []).append(row)

    summaries: list[dict[str, object]] = []
    for name, items in by_candidate.items():
        errors = [abs(float(item["observed_kph"]) - float(item["target_kph"])) for item in items]
        observed_values = [float(item["observed_kph"]) for item in items]
        target_values = [float(item["target_kph"]) for item in items]
        moved_span = max(observed_values) - min(observed_values) if observed_values else 0.0
        target_span = max(target_values) - min(target_values) if target_values else 0.0
        good = sum(error <= tolerance for error in errors)
        nonzero = sum(value > 0.5 for value in observed_values)
        summaries.append(
            {
                "candidate": name,
                "samples": len(items),
                "within_tolerance": good,
                "mean_abs_error": sum(errors) / len(errors) if errors else math.nan,
                "max_abs_error": max(errors) if errors else math.nan,
                "observed_span": moved_span,
                "target_span": target_span,
                "nonzero_observed_samples": nonzero,
                "looks_like_speed": good >= max(2, len(items) // 2) and moved_span > 0.5 * target_span,
            }
        )
    summaries.sort(key=lambda item: (-int(item["within_tolerance"]), -int(item["nonzero_observed_samples"]), float(item["mean_abs_error"])))
    return summaries


def main() -> int:
    parser = argparse.ArgumentParser(description="Drive ESP32 bench speedometer field sweeps from a laptop.")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--profile", default="rpm4000", help="static profile used for patched byte companions")
    parser.add_argument("--plan", choices=sorted(PLAN_NAMES), default="fast")
    parser.add_argument("--field", action="append", help="candidate field name; can be repeated")
    parser.add_argument("--speeds", default=",".join(str(speed) for speed in DEFAULT_SPEEDS))
    parser.add_argument("--speed-range", help="Speed range as start:end:step, for example 0:160:10")
    parser.add_argument("--settle", type=float, default=2.0)
    parser.add_argument("--recovery-settle", type=float, default=3.0)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--tolerance", type=float, default=2.0)
    parser.add_argument("--baseline-mode", default="seqidle")
    parser.add_argument("--recover-each", action="store_true", help="restore clean baseline after every typed observation")
    parser.add_argument("--no-preflight", action="store_true", help="do not start clean seqidle before the sweep")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--list-fields", action="store_true")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    all_candidates = {candidate.name: candidate for candidate in candidates()}
    if args.list_fields:
        for candidate in candidates():
            print(f"{candidate.name}: {candidate.description}")
        return 0

    selected_names = args.field or PLAN_NAMES[args.plan]
    unknown = [name for name in selected_names if name not in all_candidates]
    if unknown:
        print(f"Unknown field(s): {', '.join(unknown)}", file=sys.stderr)
        return 2
    selected = [all_candidates[name] for name in selected_names]

    if args.speed_range:
        try:
            speeds = parse_range(args.speed_range)
        except ValueError as exc:
            print(f"Bad --speed-range: {exc}", file=sys.stderr)
            return 2
    elif args.speeds == ",".join(str(speed) for speed in DEFAULT_SPEEDS):
        speeds = CONFIRM_SPEEDS
    else:
        speeds = parse_values(args.speeds)

    out = args.out
    if out is None:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        out = Path("analysis/final_correlation/bench_speed_sweeps") / f"bench_speed_sweep_{stamp}.csv"
    if not args.dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "timestamp",
        "candidate",
        "description",
        "target_kph",
        "observed_kph",
        "abs_error",
        "raw_note",
        "url",
        "http_ok",
        "status_error",
        "mcp_eflg",
        "mcp_tec",
        "mcp_rec",
        "sent_frames",
        "failed_frames",
        "notes",
    ]

    rows: list[dict[str, object]] = []
    if args.dry_run:
        print("Dry run: no requests will be sent and no CSV will be written.")
    else:
        print(f"Output CSV: {out}")
    print(f"Plan: {args.plan}; fields: {len(selected)}; speed points: {len(speeds)}")
    print("Type observed cluster speed km/h, 'fail' for S CAN failure, 'skip' to skip a point, 'next' for next field, or 'q' to quit.")

    if not args.dry_run and not args.no_preflight:
        try:
            restore_baseline(args.host, args.baseline_mode, args.timeout, args.recovery_settle)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            print(f"Preflight baseline restore failed: {exc}")

    try:
        for candidate in selected:
            print(f"\n=== {candidate.name} ===")
            print(candidate.description)
            skip_field = False
            for speed in speeds:
                url, raw_note = build_url(args.host, candidate, speed, args.profile)
                if url is None:
                    print(f"{candidate.name} target {speed}: skip ({raw_note})")
                    continue

                response: dict[str, object] = {}
                http_ok = False
                status_error = ""
                if args.dry_run:
                    print(url)
                    continue
                else:
                    print(f"\nSend target {speed} km/h: {raw_note}")
                    print(url)
                    try:
                        response = fetch_json(url, args.timeout)
                        http_ok = bool(response.get("ok", False))
                        status_error = str(response.get("error", ""))
                        if not http_ok:
                            print(f"ESP response not ok: {response}")
                        time.sleep(args.settle)
                    except (urllib.error.URLError, TimeoutError, OSError) as exc:
                        status_error = repr(exc)
                        print(f"Request failed: {status_error}")

                status = response.get("status", {}) if isinstance(response.get("status"), dict) else {}
                answer = "" if args.dry_run else input("Observed cluster speed km/h? ").strip()
                if answer.lower() in {"q", "quit", "exit"}:
                    raise KeyboardInterrupt
                if answer.lower() in {"next", "field"}:
                    if not args.dry_run:
                        try:
                            restore_baseline(args.host, args.baseline_mode, args.timeout, args.recovery_settle)
                        except (urllib.error.URLError, TimeoutError, OSError) as exc:
                            print(f"Baseline restore failed: {exc}")
                    skip_field = True
                    break

                observed = None
                notes = ""
                can_failure = is_can_failure_answer(answer)
                if can_failure:
                    notes = "S CAN communication failure"
                else:
                    try:
                        observed = parse_observed(answer)
                    except ValueError:
                        notes = answer

                abs_error = "" if observed is None else abs(observed - speed)
                row = {
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "candidate": candidate.name,
                    "description": candidate.description,
                    "target_kph": speed,
                    "observed_kph": "" if observed is None else observed,
                    "abs_error": abs_error,
                    "raw_note": raw_note,
                    "url": url,
                    "http_ok": http_ok,
                    "status_error": status_error,
                    "mcp_eflg": status.get("mcp_eflg", ""),
                    "mcp_tec": status.get("mcp_tec", ""),
                    "mcp_rec": status.get("mcp_rec", ""),
                    "sent_frames": status.get("sent_frames", ""),
                    "failed_frames": status.get("failed_frames", ""),
                    "notes": notes,
                }
                write_row(out, row, fieldnames)
                rows.append(row)

                if not args.dry_run and (can_failure or args.recover_each):
                    try:
                        restore_baseline(args.host, args.baseline_mode, args.timeout, args.recovery_settle)
                    except (urllib.error.URLError, TimeoutError, OSError) as exc:
                        print(f"Baseline restore failed: {exc}")

            if skip_field:
                continue
    except KeyboardInterrupt:
        print("\nStopped by user.")

    summaries = summarize(rows, args.tolerance)
    summary_path = out.with_name(out.stem + "_summary.csv")
    if summaries:
        with summary_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(summaries[0].keys()))
            writer.writeheader()
            writer.writerows(summaries)
        print(f"\nSummary: {summary_path}")
        for item in summaries[:8]:
            print(
                f"{item['candidate']}: {item['within_tolerance']}/{item['samples']} within "
                f"{args.tolerance:.0f} km/h, mean error {float(item['mean_abs_error']):.1f}, "
                f"span {float(item['observed_span']):.1f}"
            )
    else:
        print("\nNo observed numeric speed entries yet.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
