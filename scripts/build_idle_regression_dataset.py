#!/usr/bin/env python3
"""Build regression-ready CSVs from Dominar CAN/OBD serial logs.

The logs currently contain two useful streams:
- passive RPM debug lines, e.g. "RPM id=0x310 raw=0x000F ... data=..."
- active OBD scan rows, e.g. "OBD_CSV,...,pid_hex,name,ok,value,..."

This script joins the OBD rows with the nearest previously printed passive RPM
frame for the same passive raw value. The join is line-order based because the
debug RPM lines do not carry timestamps yet.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean, pstdev


RPM_DEBUG_RE = re.compile(
    r"RPM id=(0x[0-9A-Fa-f]+) raw=(0x[0-9A-Fa-f]+) "
    r"rpm=([0-9.]+) data=([0-9A-Fa-f ]+)"
)


RPM_SAMPLE_FIELDS = [
    "source_file",
    "line_no",
    "session",
    "loop",
    "ms",
    "passive_id_hex",
    "passive_raw_hex",
    "passive_raw_dec",
    "passive_rpm",
    "obd_rpm",
    "obd_raw_hex",
    "obd_bytes",
    "rpm_error_obd_minus_passive",
    "rpm_ratio_obd_over_passive",
    "idle_candidate",
    "passive_frame_line_no",
    "passive_frame_line_delta",
    "passive_b0",
    "passive_b1",
    "passive_b2",
    "passive_b3",
    "passive_b4",
    "passive_b5",
    "passive_b6",
    "passive_b7",
]


WIDE_FIELDS = [
    "source_file",
    "session",
    "loop",
    "ms_min",
    "ms_max",
    "passive_id_hex",
    "passive_raw_hex",
    "passive_raw_dec",
    "passive_rpm",
    "idle_candidate",
    "passive_frame_line_no",
    "passive_frame_line_delta",
    "passive_b0",
    "passive_b1",
    "passive_b2",
    "passive_b3",
    "passive_b4",
    "passive_b5",
    "passive_b6",
    "passive_b7",
    "rpm",
    "rpm_raw_hex",
    "tps",
    "tps_raw_hex",
    "coolant",
    "coolant_raw_hex",
    "iat",
    "iat_raw_hex",
    "speed",
    "speed_raw_hex",
    "map",
    "map_raw_hex",
    "ecu_voltage",
    "ecu_voltage_raw_hex",
]


PASSIVE_FRAME_FIELDS = [
    "source_file",
    "line_no",
    "session",
    "id_hex",
    "raw_hex",
    "raw_dec",
    "rpm",
    "b0",
    "b1",
    "b2",
    "b3",
    "b4",
    "b5",
    "b6",
    "b7",
]


def norm_hex(value: str) -> str:
    if not value or value == "null":
        return ""
    return f"0x{int(value, 16):04X}" if int(value, 16) <= 0xFFFF else f"0x{int(value, 16):X}"


def parse_float(value: str) -> float:
    if value in ("", "null", None):
        return math.nan
    return float(value)


def parse_int(value: str) -> int | None:
    if value in ("", "null", None):
        return None
    return int(value)


def is_idle_candidate(passive_rpm: float, idle_min: float, idle_max: float) -> bool:
    return not math.isnan(passive_rpm) and idle_min <= passive_rpm <= idle_max


def passive_columns(frame: dict | None, current_line_no: int) -> dict:
    out = {f"passive_b{i}": "" for i in range(8)}
    out["passive_frame_line_no"] = ""
    out["passive_frame_line_delta"] = ""
    if not frame:
        return out

    out["passive_frame_line_no"] = frame["line_no"]
    out["passive_frame_line_delta"] = current_line_no - frame["line_no"]
    for i in range(8):
        out[f"passive_b{i}"] = frame.get(f"b{i}", "")
    return out


def parse_inputs(paths: list[Path], idle_min: float, idle_max: float) -> tuple[list[dict], list[dict], list[dict]]:
    obd_rows: list[dict] = []
    passive_frames: list[dict] = []
    rpm_samples: list[dict] = []

    for path in paths:
        session = 0
        last_passive_by_key: dict[tuple[str, str], dict] = {}
        last_passive_any: dict | None = None

        with path.open("r", errors="ignore") as handle:
            for line_no, raw_line in enumerate(handle, 1):
                line = raw_line.strip()
                if not line:
                    continue

                if line.startswith("OBD_LOG_START"):
                    session += 1
                    continue

                rpm_match = RPM_DEBUG_RE.search(line)
                if rpm_match:
                    id_hex = rpm_match.group(1).lower()
                    raw_hex = norm_hex(rpm_match.group(2))
                    data = [int(part, 16) for part in rpm_match.group(4).split()]
                    frame = {
                        "source_file": str(path),
                        "line_no": line_no,
                        "session": session,
                        "id_hex": id_hex,
                        "raw_hex": raw_hex,
                        "raw_dec": int(raw_hex, 16),
                        "rpm": float(rpm_match.group(3)),
                    }
                    for i in range(8):
                        frame[f"b{i}"] = data[i] if i < len(data) else ""
                    passive_frames.append(frame)
                    last_passive_by_key[(id_hex, raw_hex)] = frame
                    last_passive_any = frame
                    continue

                if not line.startswith("OBD_CSV,"):
                    continue

                fields = next(csv.reader([line]))
                if len(fields) < 13 or fields[1] == "ms":
                    continue

                passive_id_hex = fields[5].lower()
                passive_raw_hex = norm_hex(fields[4])
                passive_rpm = parse_float(fields[3])
                ok = fields[8] == "1"
                value = parse_float(fields[9])
                row = {
                    "source_file": str(path),
                    "line_no": line_no,
                    "session": session,
                    "ms": parse_int(fields[1]),
                    "loop": parse_int(fields[2]),
                    "passive_rpm": passive_rpm,
                    "passive_raw_hex": passive_raw_hex,
                    "passive_raw_dec": int(passive_raw_hex, 16) if passive_raw_hex else "",
                    "passive_id_hex": passive_id_hex,
                    "pid_hex": fields[6],
                    "name": fields[7],
                    "ok": ok,
                    "value": value,
                    "unit": fields[10],
                    "obd_raw_hex": fields[11],
                    "obd_bytes": fields[12],
                }

                frame = last_passive_by_key.get((passive_id_hex, passive_raw_hex))
                if not frame and last_passive_any and last_passive_any["id_hex"] == passive_id_hex:
                    frame = last_passive_any
                row.update(passive_columns(frame, line_no))
                row["idle_candidate"] = is_idle_candidate(passive_rpm, idle_min, idle_max)
                obd_rows.append(row)

                if row["name"] == "rpm" and ok and not math.isnan(value):
                    passive = passive_rpm
                    error = value - passive if not math.isnan(passive) else math.nan
                    ratio = value / passive if not math.isnan(passive) and passive else math.nan
                    sample = {
                        "source_file": row["source_file"],
                        "line_no": row["line_no"],
                        "session": row["session"],
                        "loop": row["loop"],
                        "ms": row["ms"],
                        "passive_id_hex": row["passive_id_hex"],
                        "passive_raw_hex": row["passive_raw_hex"],
                        "passive_raw_dec": row["passive_raw_dec"],
                        "passive_rpm": passive,
                        "obd_rpm": value,
                        "obd_raw_hex": row["obd_raw_hex"],
                        "obd_bytes": row["obd_bytes"],
                        "rpm_error_obd_minus_passive": error,
                        "rpm_ratio_obd_over_passive": ratio,
                        "idle_candidate": row["idle_candidate"],
                    }
                    for key, val in passive_columns(frame, line_no).items():
                        sample[key] = val
                    rpm_samples.append(sample)

    return obd_rows, passive_frames, rpm_samples


def build_wide_rows(obd_rows: list[dict]) -> list[dict]:
    grouped: dict[tuple[str, int, int], dict] = {}

    for row in obd_rows:
        loop = row["loop"]
        if loop is None:
            continue
        key = (row["source_file"], row["session"], loop)
        wide = grouped.setdefault(
            key,
            {
                "source_file": row["source_file"],
                "session": row["session"],
                "loop": loop,
                "ms_min": row["ms"],
                "ms_max": row["ms"],
                "passive_id_hex": row["passive_id_hex"],
                "passive_raw_hex": row["passive_raw_hex"],
                "passive_raw_dec": row["passive_raw_dec"],
                "passive_rpm": row["passive_rpm"],
                "idle_candidate": row["idle_candidate"],
                "passive_frame_line_no": row["passive_frame_line_no"],
                "passive_frame_line_delta": row["passive_frame_line_delta"],
                **{f"passive_b{i}": row.get(f"passive_b{i}", "") for i in range(8)},
            },
        )

        if row["ms"] is not None:
            wide["ms_min"] = min(wide["ms_min"], row["ms"]) if wide["ms_min"] is not None else row["ms"]
            wide["ms_max"] = max(wide["ms_max"], row["ms"]) if wide["ms_max"] is not None else row["ms"]

        if row["ok"] and not math.isnan(row["value"]):
            name = row["name"]
            wide[name] = row["value"]
            wide[f"{name}_raw_hex"] = row["obd_raw_hex"]

    return [grouped[key] for key in sorted(grouped)]


def write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def fmt_float(value: float, digits: int = 2) -> str:
    if math.isnan(value):
        return "nan"
    return f"{value:.{digits}f}"


def build_summary(
    rpm_samples: list[dict],
    idle_rpm_samples: list[dict],
    stable_idle_rpm_samples: list[dict],
    wide_rows: list[dict],
) -> str:
    lines = [
        "# Idle Regression Dataset Summary",
        "",
        "Generated from serial logs containing passive RPM debug lines and OBD_CSV rows.",
        "",
        "## Counts",
        "",
        f"- RPM regression samples: {len(rpm_samples)}",
        f"- Idle RPM regression samples: {len(idle_rpm_samples)}",
        f"- Stable idle RPM regression samples: {len(stable_idle_rpm_samples)}",
        f"- Wide OBD loop rows: {len(wide_rows)}",
        "",
        "## Idle RPM Buckets",
        "",
        "| passive_raw_hex | passive_rpm | count | obd_min | obd_mean | obd_max | obd_std | mean_error | mean_ratio |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]

    by_raw: dict[str, list[dict]] = defaultdict(list)
    for row in idle_rpm_samples:
        by_raw[row["passive_raw_hex"]].append(row)

    for raw_hex in sorted(by_raw, key=lambda v: int(v, 16)):
        rows = by_raw[raw_hex]
        obd_values = [float(r["obd_rpm"]) for r in rows]
        passive = mean(float(r["passive_rpm"]) for r in rows)
        errors = [float(r["rpm_error_obd_minus_passive"]) for r in rows]
        ratios = [float(r["rpm_ratio_obd_over_passive"]) for r in rows]
        lines.append(
            "| "
            + " | ".join(
                [
                    raw_hex,
                    fmt_float(passive, 1),
                    str(len(rows)),
                    fmt_float(min(obd_values), 1),
                    fmt_float(mean(obd_values), 1),
                    fmt_float(max(obd_values), 1),
                    fmt_float(pstdev(obd_values) if len(obd_values) > 1 else 0.0, 1),
                    fmt_float(mean(errors), 1),
                    fmt_float(mean(ratios), 4),
                ]
            )
            + " |"
        )

    lines += [
        "",
        "## Stable Idle RPM Buckets",
        "",
        "| passive_raw_hex | passive_rpm | count | obd_min | obd_mean | obd_max | obd_std | mean_error | mean_ratio |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]

    stable_by_raw: dict[str, list[dict]] = defaultdict(list)
    for row in stable_idle_rpm_samples:
        stable_by_raw[row["passive_raw_hex"]].append(row)

    for raw_hex in sorted(stable_by_raw, key=lambda v: int(v, 16)):
        rows = stable_by_raw[raw_hex]
        obd_values = [float(r["obd_rpm"]) for r in rows]
        passive = mean(float(r["passive_rpm"]) for r in rows)
        errors = [float(r["rpm_error_obd_minus_passive"]) for r in rows]
        ratios = [float(r["rpm_ratio_obd_over_passive"]) for r in rows]
        lines.append(
            "| "
            + " | ".join(
                [
                    raw_hex,
                    fmt_float(passive, 1),
                    str(len(rows)),
                    fmt_float(min(obd_values), 1),
                    fmt_float(mean(obd_values), 1),
                    fmt_float(max(obd_values), 1),
                    fmt_float(pstdev(obd_values) if len(obd_values) > 1 else 0.0, 1),
                    fmt_float(mean(errors), 1),
                    fmt_float(mean(ratios), 4),
                ]
            )
            + " |"
        )

    lines += [
        "",
        "## Notes",
        "",
        "- `passive_raw_hex` / `passive_rpm` are the passive CAN snapshot recorded by firmware at the time of the OBD row.",
        "- `passive_b0..passive_b7` are joined from the nearest previously printed passive RPM debug frame with the same passive ID/raw value.",
        "- The join for `passive_b*` is line-order based, not timestamp based, because RPM debug lines do not include `ms` yet.",
        "- Stable idle rows additionally filter out OBD RPM transients and stale passive joins using CLI thresholds.",
        "- If one passive raw bucket has a wide OBD RPM range, that means passive data at the current resolution cannot uniquely predict exact ECU RPM.",
        "",
    ]

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="serial log files to parse")
    parser.add_argument("--out-dir", type=Path, default=Path("analysis"), help="output directory")
    parser.add_argument("--idle-min", type=float, default=1200.0, help="minimum passive RPM for idle candidate")
    parser.add_argument("--idle-max", type=float, default=1800.0, help="maximum passive RPM for idle candidate")
    parser.add_argument("--stable-idle-obd-max", type=float, default=1900.0, help="maximum OBD RPM for stable-idle rows")
    parser.add_argument(
        "--stable-max-line-delta",
        type=int,
        default=200,
        help="maximum line distance between OBD row and joined passive RPM debug frame for stable-idle rows",
    )
    args = parser.parse_args()

    obd_rows, passive_frames, rpm_samples = parse_inputs(args.inputs, args.idle_min, args.idle_max)
    wide_rows = build_wide_rows(obd_rows)

    idle_rpm_samples = [row for row in rpm_samples if row["idle_candidate"]]
    idle_wide_rows = [row for row in wide_rows if row.get("idle_candidate")]
    stable_idle_rpm_samples = [
        row
        for row in idle_rpm_samples
        if float(row["obd_rpm"]) <= args.stable_idle_obd_max
        and row["passive_frame_line_delta"] != ""
        and int(row["passive_frame_line_delta"]) <= args.stable_max_line_delta
    ]
    stable_idle_keys = {
        (row["source_file"], row["session"], row["loop"])
        for row in stable_idle_rpm_samples
    }
    stable_idle_wide_rows = [
        row
        for row in idle_wide_rows
        if (row["source_file"], row["session"], row["loop"]) in stable_idle_keys
    ]

    write_csv(args.out_dir / "rpm_regression_samples.csv", RPM_SAMPLE_FIELDS, rpm_samples)
    write_csv(args.out_dir / "idle_rpm_regression_samples.csv", RPM_SAMPLE_FIELDS, idle_rpm_samples)
    write_csv(args.out_dir / "stable_idle_rpm_regression_samples.csv", RPM_SAMPLE_FIELDS, stable_idle_rpm_samples)
    write_csv(args.out_dir / "obd_wide_samples.csv", WIDE_FIELDS, wide_rows)
    write_csv(args.out_dir / "idle_obd_wide_samples.csv", WIDE_FIELDS, idle_wide_rows)
    write_csv(args.out_dir / "stable_idle_obd_wide_samples.csv", WIDE_FIELDS, stable_idle_wide_rows)
    write_csv(args.out_dir / "passive_rpm_frames.csv", PASSIVE_FRAME_FIELDS, passive_frames)

    summary = build_summary(rpm_samples, idle_rpm_samples, stable_idle_rpm_samples, wide_rows)
    (args.out_dir / "idle_dataset_summary.md").write_text(summary)

    print(summary)


if __name__ == "__main__":
    main()
