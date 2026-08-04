#!/usr/bin/env python3
"""Analyze staged passive CAN captures from the ESP32 capture page.

Input is the CSV downloaded from http://192.168.4.1/capture/download.
The script does not assume formulas. It ranks bytes, nibbles, bits, and
16-bit pairs by how strongly they change across the stage markers.
"""

from __future__ import annotations

import argparse
import csv
import math
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from statistics import mean


@dataclass
class Stat:
    count: int = 0
    total: float = 0.0
    min_value: int | None = None
    max_value: int | None = None
    first_ms: int | None = None
    last_ms: int | None = None
    first_value: int | None = None
    last_value: int | None = None
    values: Counter[int] = field(default_factory=Counter)

    def add(self, ms: int, value: int) -> None:
        self.count += 1
        self.total += value
        self.min_value = value if self.min_value is None else min(self.min_value, value)
        self.max_value = value if self.max_value is None else max(self.max_value, value)
        if self.first_ms is None or ms < self.first_ms:
            self.first_ms = ms
            self.first_value = value
        if self.last_ms is None or ms >= self.last_ms:
            self.last_ms = ms
            self.last_value = value
        self.values[value] += 1

    @property
    def avg(self) -> float:
        return self.total / self.count if self.count else math.nan

    @property
    def mode(self) -> int | None:
        if not self.values:
            return None
        return self.values.most_common(1)[0][0]

    @property
    def unique_count(self) -> int:
        return len(self.values)


def parse_data_hex(value: str) -> list[int]:
    if not value:
        return []
    return [int(part, 16) for part in value.strip().split()]


def signal_values(data: list[int]) -> dict[str, int]:
    out: dict[str, int] = {}
    for i, byte in enumerate(data[:8]):
        out[f"b{i}"] = byte
        out[f"b{i}_hi"] = byte >> 4
        out[f"b{i}_lo"] = byte & 0x0F
        for bit in range(8):
            out[f"b{i}_bit{bit}"] = (byte >> bit) & 1

    for i in range(min(len(data) - 1, 7)):
        out[f"u16be_b{i}{i + 1}"] = (data[i] << 8) | data[i + 1]
        out[f"u16le_b{i}{i + 1}"] = data[i] | (data[i + 1] << 8)
    return out


def expected_value(stage: str, kind: str) -> float | None:
    text = stage.lower()
    if kind == "throttle":
        if "closed" in text or "released" in text:
            return 0.0
        for value in (25, 50, 100):
            if str(value) in text:
                return float(value)
    if kind == "speed":
        if "stopped" in text:
            return 0.0
        if "slow" in text:
            return 1.0
        if "medium" in text:
            return 2.0
        if "fast" in text:
            return 3.0
    if kind == "gear":
        if text.endswith("_n") or text == "gear_n":
            return 0.0
        for value in range(1, 7):
            if text.endswith(f"_{value}") or text == f"gear_{value}":
                return float(value)
    return None


def corr(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 2 or len(ys) < 2:
        return math.nan
    x_mean = mean(xs)
    y_mean = mean(ys)
    x_var = sum((x - x_mean) ** 2 for x in xs)
    y_var = sum((y - y_mean) ** 2 for y in ys)
    if x_var == 0 or y_var == 0:
        return math.nan
    cov = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys))
    return cov / math.sqrt(x_var * y_var)


def summarize_stage_value(stat: Stat) -> str:
    mode = stat.mode
    mode_text = "" if mode is None else str(mode)
    return f"n={stat.count};mode={mode_text};mean={stat.avg:.3f};min={stat.min_value};max={stat.max_value}"


def read_capture(path: Path):
    stage_stats: dict[tuple[str, str, str], Stat] = defaultdict(Stat)
    stage_frames: dict[str, Stat] = defaultdict(Stat)
    markers: list[dict[str, str]] = []

    with path.open("r", newline="", errors="ignore") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            row_type = (row.get("type") or "").strip()
            ms_text = row.get("ms") or "0"
            try:
                ms = int(ms_text)
            except ValueError:
                continue

            stage = (row.get("stage") or "unknown").strip() or "unknown"
            if row_type == "M":
                markers.append(row)
                continue
            if row_type != "F":
                continue

            id_hex = (row.get("id_hex") or "").lower()
            data = parse_data_hex(row.get("data_hex") or "")
            stage_frames[stage].add(ms, 1)
            for name, value in signal_values(data).items():
                stage_stats[(id_hex, name, stage)].add(ms, value)

    return stage_stats, stage_frames, markers


def build_signal_index(stage_stats: dict[tuple[str, str, str], Stat]):
    by_signal: dict[tuple[str, str], dict[str, Stat]] = defaultdict(dict)
    for (id_hex, signal, stage), stat in stage_stats.items():
        by_signal[(id_hex, signal)][stage] = stat
    return by_signal


def write_stage_summary(out_dir: Path, stage_frames: dict[str, Stat], markers: list[dict[str, str]]) -> None:
    with (out_dir / "stage_summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "stage", "frame_rows", "first_ms", "last_ms", "duration_ms", "marker_count"
        ])
        writer.writeheader()
        marker_counts = Counter((m.get("stage") or "unknown") for m in markers)
        for stage, stat in sorted(stage_frames.items(), key=lambda item: item[1].first_ms or 0):
            first_ms = stat.first_ms or 0
            last_ms = stat.last_ms or first_ms
            writer.writerow({
                "stage": stage,
                "frame_rows": stat.count,
                "first_ms": first_ms,
                "last_ms": last_ms,
                "duration_ms": last_ms - first_ms,
                "marker_count": marker_counts[stage],
            })


def write_changed_bytes(out_dir: Path, stage_stats: dict[tuple[str, str, str], Stat]) -> None:
    with (out_dir / "changed_bytes_by_stage.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "id_hex", "signal", "stage", "count", "mean", "mode", "min", "max", "unique_count"
        ])
        writer.writeheader()
        for (id_hex, signal, stage), stat in sorted(stage_stats.items()):
            writer.writerow({
                "id_hex": id_hex,
                "signal": signal,
                "stage": stage,
                "count": stat.count,
                "mean": f"{stat.avg:.6f}",
                "mode": "" if stat.mode is None else stat.mode,
                "min": stat.min_value,
                "max": stat.max_value,
                "unique_count": stat.unique_count,
            })


def signal_candidate_rows(by_signal: dict[tuple[str, str], dict[str, Stat]]) -> list[dict]:
    rows: list[dict] = []
    for (id_hex, signal), by_stage in by_signal.items():
        if not by_stage:
            continue
        modes = {stat.mode for stat in by_stage.values() if stat.mode is not None}
        min_value = min(stat.min_value for stat in by_stage.values() if stat.min_value is not None)
        max_value = max(stat.max_value for stat in by_stage.values() if stat.max_value is not None)
        total_count = sum(stat.count for stat in by_stage.values())
        changed_stage_count = len(modes)
        global_range = max_value - min_value
        score = changed_stage_count * 100000 + global_range * 10 + min(total_count, 9999)
        stage_values = " | ".join(
            f"{stage}:{summarize_stage_value(stat)}"
            for stage, stat in sorted(by_stage.items(), key=lambda item: item[0])
        )
        rows.append({
            "id_hex": id_hex,
            "signal": signal,
            "score": score,
            "total_count": total_count,
            "stage_count": len(by_stage),
            "changed_stage_count": changed_stage_count,
            "global_min": min_value,
            "global_max": max_value,
            "global_range": global_range,
            "stage_values": stage_values,
        })
    rows.sort(key=lambda row: (row["changed_stage_count"], row["global_range"], row["total_count"]), reverse=True)
    return rows


def write_candidate_signals(out_dir: Path, rows: list[dict]) -> None:
    with (out_dir / "candidate_signals.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "id_hex", "signal", "score", "total_count", "stage_count",
            "changed_stage_count", "global_min", "global_max", "global_range", "stage_values"
        ])
        writer.writeheader()
        writer.writerows(rows)


def write_kind_candidates(out_dir: Path, by_signal: dict[tuple[str, str], dict[str, Stat]], kind: str) -> None:
    rows: list[dict] = []
    for (id_hex, signal), by_stage in by_signal.items():
        xs: list[float] = []
        ys: list[float] = []
        stage_values: list[str] = []
        for stage, stat in by_stage.items():
            expected = expected_value(stage, kind)
            if expected is None:
                continue
            xs.append(expected)
            ys.append(stat.avg)
            stage_values.append(f"{stage}:{summarize_stage_value(stat)}")
        if len(xs) < 2:
            continue
        value_corr = corr(xs, ys)
        value_range = max(ys) - min(ys)
        expected_range = max(xs) - min(xs)
        if expected_range == 0 or value_range == 0:
            continue
        modes = {by_stage[stage].mode for stage in by_stage if expected_value(stage, kind) is not None}
        rows.append({
            "id_hex": id_hex,
            "signal": signal,
            "kind": kind,
            "correlation": "" if math.isnan(value_corr) else f"{value_corr:.6f}",
            "abs_correlation": 0.0 if math.isnan(value_corr) else abs(value_corr),
            "sampled_stages": len(xs),
            "changed_modes": len(modes),
            "value_range": f"{value_range:.6f}",
            "stage_values": " | ".join(sorted(stage_values)),
        })
    rows.sort(key=lambda row: (row["abs_correlation"], row["changed_modes"], float(row["value_range"])), reverse=True)

    with (out_dir / f"{kind}_candidate_signals.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "id_hex", "signal", "kind", "correlation", "abs_correlation",
            "sampled_stages", "changed_modes", "value_range", "stage_values"
        ])
        writer.writeheader()
        writer.writerows(rows)


def write_slow_moving_candidates(out_dir: Path, by_signal: dict[tuple[str, str], dict[str, Stat]]) -> None:
    rows: list[dict] = []
    for (id_hex, signal), by_stage in by_signal.items():
        warm_stats = [
            stat for stage, stat in by_stage.items()
            if "warm" in stage.lower() or "idle" in stage.lower()
        ]
        if len(warm_stats) < 2:
            continue
        first_ms_values = [stat.first_ms or 0 for stat in warm_stats]
        last_values = [float(stat.last_value or 0) for stat in warm_stats]
        value_corr = corr([float(v) for v in first_ms_values], last_values)
        value_range = max(last_values) - min(last_values)
        if math.isnan(value_corr) or value_range == 0:
            continue
        rows.append({
            "id_hex": id_hex,
            "signal": signal,
            "time_correlation": f"{value_corr:.6f}",
            "abs_time_correlation": abs(value_corr),
            "value_range": f"{value_range:.6f}",
            "stage_values": " | ".join(
                f"{stage}:{summarize_stage_value(stat)}"
                for stage, stat in sorted(by_stage.items())
                if "warm" in stage.lower() or "idle" in stage.lower()
            ),
        })
    rows.sort(key=lambda row: (row["abs_time_correlation"], float(row["value_range"])), reverse=True)

    with (out_dir / "slow_moving_candidate_signals.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "id_hex", "signal", "time_correlation", "abs_time_correlation", "value_range", "stage_values"
        ])
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("capture_csv", type=Path)
    parser.add_argument("--out-dir", type=Path, default=Path("analysis/passive_capture"))
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    stage_stats, stage_frames, markers = read_capture(args.capture_csv)
    by_signal = build_signal_index(stage_stats)
    candidates = signal_candidate_rows(by_signal)

    write_stage_summary(args.out_dir, stage_frames, markers)
    write_changed_bytes(args.out_dir, stage_stats)
    write_candidate_signals(args.out_dir, candidates)
    for kind in ("throttle", "speed", "gear"):
        write_kind_candidates(args.out_dir, by_signal, kind)
    write_slow_moving_candidates(args.out_dir, by_signal)

    print(f"Read {args.capture_csv}")
    print(f"Stages: {len(stage_frames)}")
    print(f"Signals: {len(by_signal)}")
    print(f"Wrote reports to {args.out_dir}")


if __name__ == "__main__":
    main()
