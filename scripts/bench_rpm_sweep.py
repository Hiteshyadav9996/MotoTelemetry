#!/usr/bin/env python3
"""Laptop-driven Dominar 400 cluster RPM bench sweep.

Connect the laptop to the ESP32 AP (`D400Telemetry`), keep the odometer/cluster
on the isolated bench bus, then run this script. It sends one candidate RPM
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


DEFAULT_RPMS = [2000, 2500, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 13000]
CONFIRM_RPMS = list(range(500, 10001, 500))
DEFAULT_HOST = "http://192.168.4.1"


@dataclass(frozen=True)
class Candidate:
    name: str
    description: str
    endpoint: str
    can_id: str | None = None
    byte_indexes: tuple[int, ...] = ()
    encoding: str = ""
    scale: float = 1.0
    companion_b302: bool = True


def candidates() -> list[Candidate]:
    return [
        Candidate("known_301_b0_x40", "Confirmed cluster path: 0x301 b0, raw=rpm/40, with 0x302 b1,b3,b7", "rpm301", "0x301", (0,), "u8_div", 40.0, True),
        Candidate("patch_301_b0_x40", "Same as known path, but via generic byte patch endpoint", "patch", "0x301", (0,), "u8_div", 40.0, True),
        Candidate("patch_301_b0_x50", "Single-byte alternate scale on 0x301 b0, raw=rpm/50", "patch", "0x301", (0,), "u8_div", 50.0, True),
        Candidate("patch_301_b0_x100", "Single-byte alternate scale on 0x301 b0, raw=rpm/100", "patch", "0x301", (0,), "u8_div", 100.0, True),
        Candidate("patch_310_b45_x100", "Legacy bucket candidate: 0x310 b4,b5 duplicated, raw=rpm/100", "patch", "0x310", (4, 5), "repeat_u8_div", 100.0, True),
        Candidate("patch_310_b2_x100", "Legacy alternate: 0x310 b2, raw=rpm/100", "patch", "0x310", (2,), "u8_div", 100.0, True),
        Candidate("patch_310_b2_b45_x100", "Legacy all suspected 0x310 bytes: b2,b4,b5 = rpm/100", "patch", "0x310", (2, 4, 5), "repeat_u8_div", 100.0, True),
        Candidate("patch_312_b23_be_x8", "Old smooth candidate: 0x312 b2,b3 big-endian raw=rpm*8", "patch", "0x312", (2, 3), "u16be_mul", 8.0, True),
        Candidate("patch_313_b23_be_x8", "Old smooth candidate: 0x313 b2,b3 big-endian raw=rpm*8", "patch", "0x313", (2, 3), "u16be_mul", 8.0, True),
        Candidate("patch_312_b23_be_x4", "OBD-style scale on 0x312 b2,b3 big-endian raw=rpm*4", "patch", "0x312", (2, 3), "u16be_mul", 4.0, True),
        Candidate("patch_313_b23_be_x4", "OBD-style scale on 0x313 b2,b3 big-endian raw=rpm*4", "patch", "0x313", (2, 3), "u16be_mul", 4.0, True),
        Candidate("patch_311_b01_be_x1", "0x311 b0,b1 big-endian raw=rpm", "patch", "0x311", (0, 1), "u16be_mul", 1.0, True),
        Candidate("patch_311_b01_be_x2", "0x311 b0,b1 big-endian raw=rpm*2", "patch", "0x311", (0, 1), "u16be_mul", 2.0, True),
        Candidate("patch_311_b01_be_x4", "0x311 b0,b1 big-endian raw=rpm*4", "patch", "0x311", (0, 1), "u16be_mul", 4.0, True),
        Candidate("patch_311_b23_be_x1", "0x311 b2,b3 big-endian raw=rpm", "patch", "0x311", (2, 3), "u16be_mul", 1.0, True),
        Candidate("patch_311_b23_be_x2", "0x311 b2,b3 big-endian raw=rpm*2", "patch", "0x311", (2, 3), "u16be_mul", 2.0, True),
        Candidate("patch_311_b23_be_x4", "0x311 b2,b3 big-endian raw=rpm*4", "patch", "0x311", (2, 3), "u16be_mul", 4.0, True),
        Candidate("patch_540_b3_x50", "Fast group candidate: 0x540 b3, raw=rpm/50", "patch", "0x540", (3,), "u8_div", 50.0, True),
        Candidate("patch_540_b3_x100", "Fast group candidate: 0x540 b3, raw=rpm/100", "patch", "0x540", (3,), "u8_div", 100.0, True),
        Candidate("patch_542_b45_be_x1", "Fast group candidate: 0x542 b4,b5 big-endian raw=rpm", "patch", "0x542", (4, 5), "u16be_mul", 1.0, True),
        Candidate("patch_542_b45_be_x2", "Fast group candidate: 0x542 b4,b5 big-endian raw=rpm*2", "patch", "0x542", (4, 5), "u16be_mul", 2.0, True),
        Candidate("patch_542_b45_be_x4", "Fast group candidate: 0x542 b4,b5 big-endian raw=rpm*4", "patch", "0x542", (4, 5), "u16be_mul", 4.0, True),
    ]


PLAN_NAMES = {
    "confirm": ["known_301_b0_x40", "patch_301_b0_x40"],
    "known": ["known_301_b0_x40"],
    "fast": [
        "known_301_b0_x40",
        "patch_301_b0_x40",
        "patch_310_b45_x100",
        "patch_310_b2_x100",
        "patch_312_b23_be_x8",
        "patch_313_b23_be_x8",
        "patch_311_b01_be_x2",
        "patch_311_b23_be_x2",
        "patch_540_b3_x100",
        "patch_542_b45_be_x2",
    ],
    "full": [candidate.name for candidate in candidates()],
}


def parse_rpms(value: str) -> list[int]:
    out: list[int] = []
    for token in value.replace(";", ",").replace(" ", ",").split(","):
        token = token.strip()
        if not token:
            continue
        rpm = int(token)
        if rpm < 0:
            raise ValueError(f"bad rpm {rpm}")
        out.append(rpm)
    if not out:
        raise ValueError("empty rpm list")
    return out


def parse_range(value: str) -> list[int]:
    parts = [part.strip() for part in value.split(":")]
    if len(parts) not in {2, 3} or any(not part for part in parts):
        raise ValueError("range must be start:end or start:end:step")
    start = int(parts[0])
    end = int(parts[1])
    step = int(parts[2]) if len(parts) == 3 else 500
    if start < 0 or end < 0 or step <= 0:
        raise ValueError("range values must be non-negative and step must be positive")
    if start > end:
        raise ValueError("range start must be <= end")
    return list(range(start, end + 1, step))


def round_half_up(value: float) -> int:
    return int(math.floor(value + 0.5))


def encode_bytes(candidate: Candidate, rpm: int) -> tuple[bytes | None, str]:
    if candidate.encoding == "u8_div":
        raw = round_half_up(rpm / candidate.scale)
        if raw < 0 or raw > 0xFF:
            return None, f"raw {raw} outside u8"
        return bytes([raw]), f"raw={raw} 0x{raw:02X}"

    if candidate.encoding == "repeat_u8_div":
        raw = round_half_up(rpm / candidate.scale)
        if raw < 0 or raw > 0xFF:
            return None, f"raw {raw} outside u8"
        return bytes([raw] * len(candidate.byte_indexes)), f"raw={raw} 0x{raw:02X} repeated"

    if candidate.encoding == "u16be_mul":
        raw = round_half_up(rpm * candidate.scale)
        if raw < 0 or raw > 0xFFFF:
            return None, f"raw {raw} outside u16"
        return bytes([(raw >> 8) & 0xFF, raw & 0xFF]), f"raw={raw} 0x{raw:04X} be"

    if candidate.encoding == "u16le_mul":
        raw = round_half_up(rpm * candidate.scale)
        if raw < 0 or raw > 0xFFFF:
            return None, f"raw {raw} outside u16"
        return bytes([raw & 0xFF, (raw >> 8) & 0xFF]), f"raw={raw} 0x{raw:04X} le"

    raise ValueError(f"unknown encoding {candidate.encoding}")


def build_url(host: str, candidate: Candidate, rpm: int, profile: str) -> tuple[str | None, str]:
    payload, raw_note = encode_bytes(candidate, rpm)
    if payload is None:
        return None, raw_note

    if candidate.endpoint == "rpm301":
        raw = payload[0]
        query = {
            "raw": str(raw),
            "profile": profile,
            "b302": "1,3,7",
        }
        return f"{host.rstrip('/')}/bench/rpm301?{urllib.parse.urlencode(query)}", raw_note

    if candidate.endpoint == "patch":
        query = {
            "id": candidate.can_id or "",
            "bytes": ",".join(str(index) for index in candidate.byte_indexes),
            "values": payload.hex().upper(),
            "profile": profile,
        }
        if candidate.companion_b302:
            query["b302"] = "1,3,7"
        return f"{host.rstrip('/')}/bench/patch?{urllib.parse.urlencode(query)}", raw_note

    raise ValueError(f"unknown endpoint {candidate.endpoint}")


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
    return value.strip().lower() in {"fail", "canfail", "can", "s-can", "scan", "s can", "error", "err"}


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
        if row.get("observed_rpm") in {"", None}:
            continue
        by_candidate.setdefault(str(row["candidate"]), []).append(row)

    summaries: list[dict[str, object]] = []
    for name, items in by_candidate.items():
        errors = [abs(float(item["observed_rpm"]) - float(item["target_rpm"])) for item in items]
        observed_values = [float(item["observed_rpm"]) for item in items]
        target_values = [float(item["target_rpm"]) for item in items]
        moved_span = max(observed_values) - min(observed_values) if observed_values else 0.0
        target_span = max(target_values) - min(target_values) if target_values else 0.0
        good = sum(error <= tolerance for error in errors)
        summaries.append(
            {
                "candidate": name,
                "samples": len(items),
                "within_tolerance": good,
                "mean_abs_error": sum(errors) / len(errors) if errors else math.nan,
                "max_abs_error": max(errors) if errors else math.nan,
                "observed_span": moved_span,
                "target_span": target_span,
                "looks_like_rpm": good >= max(2, len(items) // 2) and moved_span > 0.5 * target_span,
            }
        )
    summaries.sort(key=lambda item: (-int(item["within_tolerance"]), float(item["mean_abs_error"])))
    return summaries


def main() -> int:
    parser = argparse.ArgumentParser(description="Drive ESP32 bench RPM field sweeps from a laptop.")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--profile", default="rpm4000", help="static profile used for patched byte companions")
    parser.add_argument("--plan", choices=sorted(PLAN_NAMES), default="fast")
    parser.add_argument("--field", action="append", help="candidate field name; can be repeated")
    parser.add_argument("--rpms", default=",".join(str(rpm) for rpm in DEFAULT_RPMS))
    parser.add_argument("--rpm-range", help="RPM range as start:end:step, for example 500:10000:500")
    parser.add_argument("--settle", type=float, default=2.0)
    parser.add_argument("--recovery-settle", type=float, default=3.0)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--tolerance", type=float, default=150.0)
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
    if args.rpm_range:
        try:
            rpms = parse_range(args.rpm_range)
        except ValueError as exc:
            print(f"Bad --rpm-range: {exc}", file=sys.stderr)
            return 2
    elif args.plan == "confirm" and args.rpms == ",".join(str(rpm) for rpm in DEFAULT_RPMS):
        rpms = CONFIRM_RPMS
    else:
        rpms = parse_rpms(args.rpms)

    out = args.out
    if out is None:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        out = Path("analysis/final_correlation/bench_rpm_sweeps") / f"bench_rpm_sweep_{stamp}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "timestamp",
        "candidate",
        "description",
        "target_rpm",
        "observed_rpm",
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
    print(f"Output CSV: {out}")
    print(f"Plan: {args.plan}; fields: {len(selected)}; rpm points: {len(rpms)}")
    print("Type observed cluster RPM, 'fail' for S CAN failure, 'skip' to skip a point, 'next' for next field, or 'q' to quit.")

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
            for rpm in rpms:
                url, raw_note = build_url(args.host, candidate, rpm, args.profile)
                if url is None:
                    print(f"{candidate.name} target {rpm}: skip ({raw_note})")
                    continue

                response: dict[str, object] = {}
                http_ok = False
                status_error = ""
                if args.dry_run:
                    print(url)
                else:
                    print(f"\nSend target {rpm} rpm: {raw_note}")
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
                prompt = "Observed cluster RPM? "
                answer = "" if args.dry_run else input(prompt).strip()
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

                abs_error = "" if observed is None else abs(observed - rpm)
                row = {
                    "timestamp": datetime.now().isoformat(timespec="seconds"),
                    "candidate": candidate.name,
                    "description": candidate.description,
                    "target_rpm": rpm,
                    "observed_rpm": "" if observed is None else observed,
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
                f"{args.tolerance:.0f} rpm, mean error {float(item['mean_abs_error']):.1f}, "
                f"span {float(item['observed_span']):.1f}"
            )
    else:
        print("\nNo observed numeric RPM entries yet.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
