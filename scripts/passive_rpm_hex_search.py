#!/usr/bin/env python3
"""Passive CAN RPM search using OBD RPM rows only as validation truth.

This intentionally excludes OBD response IDs (0x7e8..0x7ef) from candidates.
It searches passive hex IDs for RPM-like data with timing lag, byte fields,
arbitrary bit fields, and deterministic full-payload lower bounds.
"""

import argparse
import bisect
import csv
import math
from collections import Counter, defaultdict
from pathlib import Path


DEFAULT_INPUT = Path("analysis/final_correlation/d400_correlation_combined.csv")
DEFAULT_OUT_DIR = Path("analysis/final_correlation/passive_rpm_hex_search")
OBD_RESPONSE_IDS = {f"0x{value:x}" for value in range(0x7E8, 0x7F0)}


def parse_int(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def parse_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_bytes(data_hex):
    try:
        return [int(part, 16) for part in data_hex.split()]
    except (AttributeError, ValueError):
        return []


def signed16(value):
    return value - 0x10000 if value & 0x8000 else value


def median(values):
    if not values:
        return float("nan")
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def percentile(values, fraction):
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[int(round((len(ordered) - 1) * fraction))]


def linear_fit(xs, ys, min_unique=2):
    if len(xs) < 24 or len(set(xs)) < min_unique:
        return None
    n = len(xs)
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    denom = sum((x - mean_x) ** 2 for x in xs)
    if denom <= 0:
        return None
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / denom
    intercept = mean_y - slope * mean_x
    preds = [slope * x + intercept for x in xs]
    errors = [y - pred for y, pred in zip(ys, preds)]
    abs_errors = [abs(error) for error in errors]
    ss_tot = sum((y - mean_y) ** 2 for y in ys)
    ss_res = sum(error * error for error in errors)
    return {
        "n": n,
        "unique_x": len(set(xs)),
        "slope": slope,
        "intercept": intercept,
        "mae": sum(abs_errors) / n,
        "median_abs_err": median(abs_errors),
        "p90_abs_err": percentile(abs_errors, 0.90),
        "max_abs_err": max(abs_errors),
        "under_10": sum(1 for error in abs_errors if error < 10.0),
        "r2": 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan"),
    }


def fmt(value, decimals=6):
    if value is None:
        return ""
    if isinstance(value, float):
        if math.isnan(value):
            return ""
        return f"{value:.{decimals}f}"
    return str(value)


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def load_data(path):
    rows_by_source = defaultdict(list)
    truth = []
    frames = defaultdict(lambda: defaultdict(list))

    with path.open(newline="") as handle:
        for index, row in enumerate(csv.DictReader(handle)):
            source = row["source_file"]
            ms = parse_int(row.get("ms"))
            source_row = parse_int(row.get("source_row"))
            row["_index"] = index
            row["_ms"] = ms
            row["_source_row"] = source_row
            rows_by_source[source].append(row)

            if ms is None:
                continue
            if (
                row.get("type") == "O"
                and row.get("pid_name") == "rpm"
                and row.get("pid_hex", "").lower() == "0x0c"
                and row.get("ok") == "1"
            ):
                value = parse_float(row.get("value"))
                if value is not None:
                    truth.append({
                        "source_file": source,
                        "ms": ms,
                        "source_row": row.get("source_row", ""),
                        "rpm": value,
                    })
            elif row.get("type") == "F":
                can_id = row.get("id_hex", "").lower()
                data = parse_bytes(row.get("data_hex", ""))
                if can_id and can_id not in OBD_RESPONSE_IDS and data:
                    frames[source][can_id].append({
                        "ms": ms,
                        "source_row": row.get("source_row", ""),
                        "data": data,
                        "data_hex": row.get("data_hex", ""),
                    })

    for source in rows_by_source:
        rows_by_source[source].sort(key=lambda row: (
            row["_source_row"] if row["_source_row"] is not None else 10**12,
            row["_index"],
        ))
    for source in frames:
        for can_id in frames[source]:
            frames[source][can_id].sort(key=lambda row: row["ms"])
    return truth, frames


def nearest_frame(frames, source, can_id, target_ms, max_distance_ms):
    candidates = frames.get(source, {}).get(can_id, [])
    if not candidates:
        return None
    times = [row["ms"] for row in candidates]
    index = bisect.bisect_left(times, target_ms)
    near = []
    if index < len(candidates):
        near.append(candidates[index])
    if index > 0:
        near.append(candidates[index - 1])
    if not near:
        return None
    best = min(near, key=lambda row: abs(row["ms"] - target_ms))
    if abs(best["ms"] - target_ms) > max_distance_ms:
        return None
    return best


def byte_features(data):
    features = {}
    for index, byte in enumerate(data[:8]):
        features[f"b{index}"] = byte
        features[f"b{index}_hi"] = byte >> 4
        features[f"b{index}_lo"] = byte & 0x0F
    for index in range(min(len(data) - 1, 7)):
        be = (data[index] << 8) | data[index + 1]
        le = (data[index + 1] << 8) | data[index]
        features[f"be16_{index}_{index + 1}"] = be
        features[f"le16_{index + 1}_{index}"] = le
        features[f"sbe16_{index}_{index + 1}"] = signed16(be)
        features[f"sle16_{index + 1}_{index}"] = signed16(le)
    for index in range(min(len(data) - 2, 6)):
        be = (data[index] << 16) | (data[index + 1] << 8) | data[index + 2]
        le = (data[index + 2] << 16) | (data[index + 1] << 8) | data[index]
        features[f"be24_{index}_{index + 2}"] = be
        features[f"le24_{index + 2}_{index}"] = le
    return features


def all_candidate_ids(frames):
    return sorted({can_id for source in frames.values() for can_id in source})


def lagged_byte_search(truth, frames, lags, max_distance_ms):
    ids = all_candidate_ids(frames)
    rows = []
    for lag in lags:
        samples = defaultdict(lambda: [[], []])
        for sample in truth:
            target_ms = sample["ms"] + lag
            for can_id in ids:
                frame = nearest_frame(frames, sample["source_file"], can_id, target_ms, max_distance_ms)
                if frame is None:
                    continue
                for feature, value in byte_features(frame["data"]).items():
                    xs, ys = samples[(can_id, feature)]
                    xs.append(float(value))
                    ys.append(sample["rpm"])
        for (can_id, feature), (xs, ys) in samples.items():
            if len(xs) < 300:
                continue
            fit = linear_fit(xs, ys, min_unique=8)
            if fit is None:
                continue
            rows.append({
                "lag_ms": lag,
                "id_hex": can_id,
                "feature": feature,
                **fit,
            })
    rows.sort(key=lambda row: (row["mae"], row["max_abs_err"], -row["under_10"]))
    return rows


def bitfield_search(truth, frames, lags, max_distance_ms):
    ids = all_candidate_ids(frames)
    rows = []
    for lag in lags:
        selected = defaultdict(list)
        for sample in truth:
            target_ms = sample["ms"] + lag
            for can_id in ids:
                frame = nearest_frame(frames, sample["source_file"], can_id, target_ms, max_distance_ms)
                if frame is not None:
                    selected[can_id].append((frame["data"], sample["rpm"]))
        for can_id, samples in selected.items():
            if len(samples) < 300:
                continue
            padded = [(bytes(data).ljust(8, b"\x00")[:8], rpm) for data, rpm in samples]
            int_sets = {
                "le": [int.from_bytes(data, "little") for data, _rpm in padded],
                "be": [int.from_bytes(data, "big") for data, _rpm in padded],
            }
            ys = [rpm for _data, rpm in padded]
            for endian, values in int_sets.items():
                for length in range(4, 33):
                    mask = (1 << length) - 1
                    for start in range(0, 65 - length):
                        xs = [float((value >> start) & mask) for value in values]
                        fit = linear_fit(xs, ys, min_unique=8)
                        if fit is None:
                            continue
                        rows.append({
                            "lag_ms": lag,
                            "id_hex": can_id,
                            "field": f"{endian}_bit{start}_{length}",
                            **fit,
                        })
    rows.sort(key=lambda row: (row["mae"], row["max_abs_err"], -row["under_10"]))
    return rows


def full_payload_lower_bounds(truth, frames, lags, max_distance_ms):
    ids = all_candidate_ids(frames)
    rows = []
    for lag in lags:
        for can_id in ids:
            groups = defaultdict(list)
            for sample in truth:
                frame = nearest_frame(
                    frames,
                    sample["source_file"],
                    can_id,
                    sample["ms"] + lag,
                    max_distance_ms,
                )
                if frame is not None:
                    groups[frame["data_hex"]].append(sample["rpm"])
            if not groups:
                continue
            repeated = 0
            conflicting = 0
            worst_payload = ""
            worst_span = 0.0
            for payload, rpms in groups.items():
                if len(rpms) <= 1:
                    continue
                repeated += 1
                span = max(rpms) - min(rpms)
                if span > 20.0:
                    conflicting += 1
                if span > worst_span:
                    worst_span = span
                    worst_payload = payload
            rows.append({
                "lag_ms": lag,
                "id_hex": can_id,
                "n": sum(len(values) for values in groups.values()),
                "unique_payloads": len(groups),
                "repeated_payloads": repeated,
                "conflicting_repeats_over_20rpm": conflicting,
                "deterministic_max_error_lower_bound": worst_span / 2.0,
                "worst_span": worst_span,
                "worst_payload": worst_payload,
            })
    rows.sort(key=lambda row: (row["lag_ms"], row["deterministic_max_error_lower_bound"]), reverse=True)
    return rows


def oracle_301_b0(truth, frames, windows_ms):
    rows = []
    for window in windows_ms:
        errors = []
        for sample in truth:
            candidates = frames.get(sample["source_file"], {}).get("0x301", [])
            nearby = [frame for frame in candidates if abs(frame["ms"] - sample["ms"]) <= window]
            if not nearby:
                continue
            best = min(nearby, key=lambda frame: abs(sample["rpm"] - frame["data"][0] * 40.0))
            errors.append(abs(sample["rpm"] - best["data"][0] * 40.0))
        if errors:
            rows.append({
                "window_ms": window,
                "n": len(errors),
                "mae": sum(errors) / len(errors),
                "median_abs_err": median(errors),
                "p90_abs_err": percentile(errors, 0.90),
                "max_abs_err": max(errors),
                "under_10": sum(1 for error in errors if error < 10.0),
            })
    return rows


def interpolate_301_b0(truth, frames, lags):
    rows = []
    for label, scale, intercept in (
        ("raw_times_40", 1.0, 0.0),
        ("same_time_linear_fit", 39.58264334076262 / 40.0, 49.51124632460915),
        ("lag70_linear_fit", 39.88531979618974 / 40.0, 26.743485163035984),
    ):
        for lag in lags:
            errors = []
            for sample in truth:
                candidates = frames.get(sample["source_file"], {}).get("0x301", [])
                if len(candidates) < 2:
                    continue
                target_ms = sample["ms"] + lag
                times = [row["ms"] for row in candidates]
                index = bisect.bisect_left(times, target_ms)
                if index == 0 or index >= len(candidates):
                    continue
                before = candidates[index - 1]
                after = candidates[index]
                if abs(before["ms"] - target_ms) > 300 or abs(after["ms"] - target_ms) > 300:
                    continue
                if after["ms"] == before["ms"]:
                    continue
                before_rpm = before["data"][0] * 40.0
                after_rpm = after["data"][0] * 40.0
                ratio = (target_ms - before["ms"]) / (after["ms"] - before["ms"])
                pred = before_rpm + (after_rpm - before_rpm) * ratio
                pred = pred * scale + intercept
                errors.append(abs(sample["rpm"] - pred))
            if errors:
                rows.append({
                    "model": label,
                    "lag_ms": lag,
                    "n": len(errors),
                    "mae": sum(errors) / len(errors),
                    "median_abs_err": median(errors),
                    "p90_abs_err": percentile(errors, 0.90),
                    "max_abs_err": max(errors),
                    "under_10": sum(1 for error in errors if error < 10.0),
                })
    rows.sort(key=lambda row: (row["mae"], row["max_abs_err"]))
    return rows


def payload_lookup_validation(truth, frames, can_id="0x302", max_distance_ms=80):
    samples = []
    for sample in truth:
        frame = nearest_frame(frames, sample["source_file"], can_id, sample["ms"], max_distance_ms)
        if frame is not None:
            samples.append((sample, tuple(frame["data"])))

    def score_errors(errors):
        return {
            "n": len(errors),
            "mae": sum(errors) / len(errors) if errors else float("nan"),
            "median_abs_err": median(errors),
            "p90_abs_err": percentile(errors, 0.90),
            "max_abs_err": max(errors) if errors else float("nan"),
            "under_10": sum(1 for error in errors if error < 10.0),
        }

    rows = []
    by_payload = defaultdict(list)
    for sample, payload in samples:
        by_payload[payload].append(sample["rpm"])
    all_data_errors = []
    for sample, payload in samples:
        values = sorted(by_payload[payload])
        pred = values[len(values) // 2]
        all_data_errors.append(abs(sample["rpm"] - pred))
    rows.append({
        "id_hex": can_id,
        "method": "same_data_payload_median",
        "unique_payloads": len(by_payload),
        "same_payload_predictions": len(samples),
        **score_errors(all_data_errors),
    })

    def payload_distance(left, right):
        return sum((a - b) * (a - b) for a, b in zip(left, right))

    loo_errors = []
    same_payload_count = 0
    for index, (sample, payload) in enumerate(samples):
        train = [(other, other_payload) for i, (other, other_payload) in enumerate(samples) if i != index]
        same_values = [other["rpm"] for other, other_payload in train if other_payload == payload]
        if same_values:
            same_payload_count += 1
            values = sorted(same_values)
            pred = values[len(values) // 2]
        else:
            pred = min(train, key=lambda item: payload_distance(payload, item[1]))[0]["rpm"]
        loo_errors.append(abs(sample["rpm"] - pred))
    rows.append({
        "id_hex": can_id,
        "method": "leave_one_out_same_payload_else_nearest",
        "unique_payloads": len(by_payload),
        "same_payload_predictions": same_payload_count,
        **score_errors(loo_errors),
    })

    loso_errors = []
    loso_same_payload_count = 0
    for sample, payload in samples:
        train = [(other, other_payload) for other, other_payload in samples if other["source_file"] != sample["source_file"]]
        if not train:
            continue
        same_values = [other["rpm"] for other, other_payload in train if other_payload == payload]
        if same_values:
            loso_same_payload_count += 1
            values = sorted(same_values)
            pred = values[len(values) // 2]
        else:
            pred = min(train, key=lambda item: payload_distance(payload, item[1]))[0]["rpm"]
        loso_errors.append(abs(sample["rpm"] - pred))
    rows.append({
        "id_hex": can_id,
        "method": "leave_source_out_same_payload_else_nearest",
        "unique_payloads": len(by_payload),
        "same_payload_predictions": loso_same_payload_count,
        **score_errors(loso_errors),
    })
    return rows


def scaled_raw_presence(truth, frames, window_ms):
    ids = all_candidate_ids(frames)
    counts = Counter()
    for sample in truth:
        targets = {
            int(round(sample["rpm"] * 4.0)): "rpm_times_4",
            int(round(sample["rpm"] * 2.0)): "rpm_times_2",
            int(round(sample["rpm"])): "rpm",
            int(round(sample["rpm"] / 2.0)): "rpm_div_2",
            int(round(sample["rpm"] / 4.0)): "rpm_div_4",
        }
        for can_id in ids:
            candidates = frames.get(sample["source_file"], {}).get(can_id, [])
            for frame in candidates:
                if abs(frame["ms"] - sample["ms"]) > window_ms:
                    continue
                for feature, value in byte_features(frame["data"]).items():
                    label = targets.get(value)
                    if label:
                        counts[(can_id, feature, label)] += 1
    rows = [
        {
            "id_hex": can_id,
            "feature": feature,
            "target": target,
            "matches": count,
        }
        for (can_id, feature, target), count in counts.items()
    ]
    rows.sort(key=lambda row: row["matches"], reverse=True)
    return rows


def write_report(
    path,
    truth,
    byte_rows,
    bit_rows,
    lower_rows,
    oracle_rows,
    raw_rows,
    interpolation_rows,
    lookup_rows,
):
    best_byte = byte_rows[0] if byte_rows else None
    best_bit = bit_rows[0] if bit_rows else None
    with path.open("w") as handle:
        handle.write("# Passive RPM Hex-ID Search\n\n")
        handle.write("OBD PID `0x0C` rows are validation truth only. Candidate frames exclude `0x7e8..0x7ef`.\n\n")
        handle.write(f"Validation RPM samples: `{len(truth)}`.\n\n")
        handle.write("## Best Passive Candidates\n\n")
        if best_byte:
            handle.write(
                f"- Best lagged byte/word feature: `{best_byte['id_hex']} {best_byte['feature']}` "
                f"at lag `{best_byte['lag_ms']}` ms, formula "
                f"`rpm = {best_byte['slope']:.6g} * raw + {best_byte['intercept']:.6g}`. "
                f"MAE `{best_byte['mae']:.2f}`, P90 `{best_byte['p90_abs_err']:.2f}`, "
                f"max `{best_byte['max_abs_err']:.2f}`, under 10 rpm `{best_byte['under_10']}/{best_byte['n']}`.\n"
            )
        if best_bit:
            handle.write(
                f"- Best arbitrary bitfield: `{best_bit['id_hex']} {best_bit['field']}` "
                f"at lag `{best_bit['lag_ms']}` ms. MAE `{best_bit['mae']:.2f}`, "
                f"P90 `{best_bit['p90_abs_err']:.2f}`, max `{best_bit['max_abs_err']:.2f}`, "
                f"under 10 rpm `{best_bit['under_10']}/{best_bit['n']}`.\n"
            )
        handle.write("\nNo passive candidate in this search reaches the required `<10 rpm` error for every validation sample.\n\n")
        handle.write("## Deterministic Payload Lower Bound\n\n")
        handle.write(
            "For repeated full payloads, any deterministic formula using only that payload has a best-case "
            "max error of at least half the RPM span for that payload. See "
            "`full_payload_lower_bounds.csv`.\n\n"
        )
        smallest_bounds = sorted(
            lower_rows,
            key=lambda row: float(row["deterministic_max_error_lower_bound"]),
        )
        handle.write("Smallest full-payload lower bounds:\n\n")
        for row in smallest_bounds[:8]:
            handle.write(
                f"- lag `{row['lag_ms']}` ms `{row['id_hex']}` lower-bound max error "
                f"`{float(row['deterministic_max_error_lower_bound']):.1f}` rpm; "
                f"worst payload `{row['worst_payload']}`.\n"
            )
        handle.write("\nKey RPM-candidate IDs:\n\n")
        for wanted in ("0x301", "0x302", "0x310", "0x542"):
            for row in lower_rows:
                if row["id_hex"] != wanted:
                    continue
                handle.write(
                    f"- lag `{row['lag_ms']}` ms `{row['id_hex']}`: "
                    f"unique payloads `{row['unique_payloads']}/{row['n']}`, "
                    f"conflicting repeats `{row['conflicting_repeats_over_20rpm']}`, "
                    f"lower-bound max error `{float(row['deterministic_max_error_lower_bound']):.1f}` rpm.\n"
                )
        handle.write("\n")
        if oracle_rows:
            best_oracle = min(oracle_rows, key=lambda row: row["max_abs_err"])
            handle.write("## 0x301 Byte0 Oracle Check\n\n")
            handle.write(
                f"Even if an oracle chooses the closest `0x301 b0 * 40` frame in a window, best tested max error is "
                f"`{best_oracle['max_abs_err']:.1f}` rpm at window `{best_oracle['window_ms']}` ms. "
                "So `0x301 b0` alone cannot be the exact decoder.\n\n"
            )
        if interpolation_rows:
            best_interpolation = interpolation_rows[0]
            handle.write("## 0x301 Interpolation Check\n\n")
            handle.write(
                f"Best interpolation of `0x301 b0` is `{best_interpolation['model']}` at lag "
                f"`{best_interpolation['lag_ms']}` ms: MAE `{best_interpolation['mae']:.2f}`, "
                f"P90 `{best_interpolation['p90_abs_err']:.2f}`, max "
                f"`{best_interpolation['max_abs_err']:.2f}`, under 10 rpm "
                f"`{best_interpolation['under_10']}/{best_interpolation['n']}`.\n\n"
            )
        if lookup_rows:
            handle.write("## 0x302 Payload Lookup Check\n\n")
            for row in lookup_rows:
                handle.write(
                    f"- `{row['method']}`: MAE `{row['mae']:.2f}`, P90 "
                    f"`{row['p90_abs_err']:.2f}`, max `{row['max_abs_err']:.2f}`, "
                    f"under 10 rpm `{row['under_10']}/{row['n']}`, same-payload predictions "
                    f"`{row['same_payload_predictions']}`.\n"
                )
            handle.write(
                "\nThe same-data lookup passes only by memorizing the validation set; leave-one-out and "
                "leave-source-out checks fail, so this is not accepted as a decoder.\n\n"
            )
        if raw_rows:
            handle.write("## Direct Raw Presence\n\n")
            handle.write(
                f"The most common direct scaled-RPM raw match is `{raw_rows[0]['id_hex']} "
                f"{raw_rows[0]['feature']} -> {raw_rows[0]['target']}` with only "
                f"`{raw_rows[0]['matches']}` matches, not a consistent embedding.\n\n"
            )
        handle.write("## Generated Files\n\n")
        for name in (
            "lagged_byte_feature_scores.csv",
            "bitfield_scores.csv",
            "full_payload_lower_bounds.csv",
            "oracle_0x301_b0.csv",
            "interpolated_0x301_b0.csv",
            "payload_lookup_validation.csv",
            "scaled_raw_presence.csv",
        ):
            handle.write(f"- `{name}`\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    truth, frames = load_data(args.input)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    byte_rows = lagged_byte_search(truth, frames, range(-150, 55, 5), 60)
    bit_rows = bitfield_search(truth, frames, [-120, -100, -80, -70, -60, -40, 0], 60)
    lower_rows = full_payload_lower_bounds(truth, frames, [0, -70], 80)
    oracle_rows = oracle_301_b0(truth, frames, [20, 40, 80, 120, 200, 400])
    interpolation_rows = interpolate_301_b0(truth, frames, range(-150, 85, 5))
    lookup_rows = payload_lookup_validation(truth, frames, "0x302", 80)
    raw_rows = scaled_raw_presence(truth, frames, 80)

    score_fields = [
        "lag_ms", "id_hex", "feature", "n", "unique_x", "slope", "intercept",
        "r2", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10",
    ]
    bit_fields = [
        "lag_ms", "id_hex", "field", "n", "unique_x", "slope", "intercept",
        "r2", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10",
    ]
    lower_fields = [
        "lag_ms", "id_hex", "n", "unique_payloads", "repeated_payloads",
        "conflicting_repeats_over_20rpm", "deterministic_max_error_lower_bound",
        "worst_span", "worst_payload",
    ]
    oracle_fields = ["window_ms", "n", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10"]
    interpolation_fields = ["model", "lag_ms", "n", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10"]
    lookup_fields = [
        "id_hex", "method", "unique_payloads", "same_payload_predictions",
        "n", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10",
    ]
    raw_fields = ["id_hex", "feature", "target", "matches"]

    write_csv(args.out_dir / "lagged_byte_feature_scores.csv", byte_rows, score_fields)
    write_csv(args.out_dir / "bitfield_scores.csv", bit_rows, bit_fields)
    write_csv(args.out_dir / "full_payload_lower_bounds.csv", lower_rows, lower_fields)
    write_csv(args.out_dir / "oracle_0x301_b0.csv", oracle_rows, oracle_fields)
    write_csv(args.out_dir / "interpolated_0x301_b0.csv", interpolation_rows, interpolation_fields)
    write_csv(args.out_dir / "payload_lookup_validation.csv", lookup_rows, lookup_fields)
    write_csv(args.out_dir / "scaled_raw_presence.csv", raw_rows, raw_fields)
    write_report(
        args.out_dir / "passive_rpm_hex_search_report.md",
        truth,
        byte_rows,
        bit_rows,
        lower_rows,
        oracle_rows,
        raw_rows,
        interpolation_rows,
        lookup_rows,
    )

    print(f"truth_samples={len(truth)}")
    print(f"out_dir={args.out_dir}")
    if byte_rows:
        best = byte_rows[0]
        print(
            f"best_byte={best['id_hex']} {best['feature']} lag={best['lag_ms']} "
            f"mae={best['mae']:.3f} max={best['max_abs_err']:.3f} under10={best['under_10']}/{best['n']}"
        )
    if bit_rows:
        best = bit_rows[0]
        print(
            f"best_bit={best['id_hex']} {best['field']} lag={best['lag_ms']} "
            f"mae={best['mae']:.3f} max={best['max_abs_err']:.3f} under10={best['under_10']}/{best['n']}"
        )


if __name__ == "__main__":
    main()
