#!/usr/bin/env python3
"""Sequence-aware passive RPM search.

OBD RPM rows are validation truth only. Candidate features are built from short
histories of passive CAN frames, excluding OBD response IDs.
"""

import argparse
import bisect
import csv
import math
from collections import defaultdict
from pathlib import Path


DEFAULT_INPUT = Path("analysis/final_correlation/d400_correlation_combined.csv")
DEFAULT_OUT_DIR = Path("analysis/final_correlation/passive_rpm_sequence_search")
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


def score_errors(errors):
    if not errors:
        return {
            "n": 0,
            "mae": float("nan"),
            "median_abs_err": float("nan"),
            "p90_abs_err": float("nan"),
            "max_abs_err": float("nan"),
            "under_10": 0,
        }
    return {
        "n": len(errors),
        "mae": sum(errors) / len(errors),
        "median_abs_err": median(errors),
        "p90_abs_err": percentile(errors, 0.90),
        "max_abs_err": max(errors),
        "under_10": sum(1 for error in errors if error < 10.0),
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
    truth = []
    frames = defaultdict(lambda: defaultdict(list))
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            source = row["source_file"]
            ms = parse_int(row.get("ms"))
            if ms is None:
                continue
            if (
                row.get("type") == "O"
                and row.get("pid_name") == "rpm"
                and row.get("pid_hex", "").lower() == "0x0c"
                and row.get("ok") == "1"
            ):
                rpm = parse_float(row.get("value"))
                if rpm is not None:
                    truth.append({
                        "source_file": source,
                        "source_row": row.get("source_row", ""),
                        "ms": ms,
                        "rpm": rpm,
                    })
            elif row.get("type") == "F":
                can_id = row.get("id_hex", "").lower()
                data = parse_bytes(row.get("data_hex", ""))
                if can_id and can_id not in OBD_RESPONSE_IDS and data:
                    frames[source][can_id].append({
                        "ms": ms,
                        "data": data,
                        "data_hex": row.get("data_hex", ""),
                    })
    for source in frames:
        for can_id in frames[source]:
            frames[source][can_id].sort(key=lambda row: row["ms"])
    return truth, frames


def nearest_frame(frames, source, can_id, target_ms, max_distance_ms):
    rows = frames.get(source, {}).get(can_id, [])
    if not rows:
        return None
    times = [row["ms"] for row in rows]
    index = bisect.bisect_left(times, target_ms)
    candidates = []
    if index < len(rows):
        candidates.append(rows[index])
    if index > 0:
        candidates.append(rows[index - 1])
    if not candidates:
        return None
    best = min(candidates, key=lambda row: abs(row["ms"] - target_ms))
    if abs(best["ms"] - target_ms) > max_distance_ms:
        return None
    return best


def build_sequence_dataset(truth, frames, ids, offsets, max_distance_ms):
    rows = []
    feature_names = []
    for can_id in ids:
        for offset in offsets:
            feature_names.append(f"{can_id}@{offset}_age_ms")
            for index in range(8):
                feature_names.append(f"{can_id}@{offset}_b{index}")

    for sample in truth:
        values = []
        complete = True
        for can_id in ids:
            for offset in offsets:
                frame = nearest_frame(
                    frames,
                    sample["source_file"],
                    can_id,
                    sample["ms"] + offset,
                    max_distance_ms,
                )
                if frame is None:
                    complete = False
                    break
                data = frame["data"] + [0] * (8 - len(frame["data"]))
                values.append(float(frame["ms"] - (sample["ms"] + offset)))
                values.extend(float(value) for value in data[:8])
            if not complete:
                break
        if complete:
            rows.append({
                "source_file": sample["source_file"],
                "source_row": sample["source_row"],
                "ms": sample["ms"],
                "rpm": sample["rpm"],
                "features": values,
            })
    return feature_names, rows


def payload_key_dataset(truth, frames, ids, offsets, max_distance_ms):
    rows = []
    for sample in truth:
        parts = []
        complete = True
        for can_id in ids:
            for offset in offsets:
                frame = nearest_frame(
                    frames,
                    sample["source_file"],
                    can_id,
                    sample["ms"] + offset,
                    max_distance_ms,
                )
                if frame is None:
                    complete = False
                    break
                age_bucket = int(round((frame["ms"] - (sample["ms"] + offset)) / 5.0))
                parts.append((can_id, offset, age_bucket, frame["data_hex"]))
            if not complete:
                break
        if complete:
            rows.append({
                "source_file": sample["source_file"],
                "source_row": sample["source_row"],
                "ms": sample["ms"],
                "rpm": sample["rpm"],
                "key": tuple(parts),
            })
    return rows


def solve_linear_system(matrix, vector):
    size = len(vector)
    augmented = [list(matrix[row]) + [vector[row]] for row in range(size)]
    for col in range(size):
        pivot = max(range(col, size), key=lambda row: abs(augmented[row][col]))
        if abs(augmented[pivot][col]) < 1e-10:
            return None
        if pivot != col:
            augmented[col], augmented[pivot] = augmented[pivot], augmented[col]
        pivot_value = augmented[col][col]
        for item in range(col, size + 1):
            augmented[col][item] /= pivot_value
        for row in range(size):
            if row == col:
                continue
            factor = augmented[row][col]
            if factor == 0:
                continue
            for item in range(col, size + 1):
                augmented[row][item] -= factor * augmented[col][item]
    return [augmented[row][size] for row in range(size)]


def standardize(train_rows, eval_rows, selected_indexes):
    means = []
    scales = []
    for index in selected_indexes:
        values = [row["features"][index] for row in train_rows]
        mean = sum(values) / len(values)
        variance = sum((value - mean) ** 2 for value in values) / len(values)
        scale = math.sqrt(variance) or 1.0
        means.append(mean)
        scales.append(scale)

    def transform(rows):
        out = []
        for row in rows:
            values = [1.0]
            for index, mean, scale in zip(selected_indexes, means, scales):
                values.append((row["features"][index] - mean) / scale)
            out.append(values)
        return out

    return transform(train_rows), transform(eval_rows)


def fit_ridge(train_rows, feature_count, ridge):
    if not train_rows:
        return None
    cols = feature_count
    xtx = [[0.0 for _ in range(cols)] for _ in range(cols)]
    xty = [0.0 for _ in range(cols)]
    for row in train_rows:
        x = row["x"]
        y = row["rpm"]
        for i in range(cols):
            xty[i] += x[i] * y
            for j in range(cols):
                xtx[i][j] += x[i] * x[j]
    for i in range(1, cols):
        xtx[i][i] += ridge
    return solve_linear_system(xtx, xty)


def predict(coefficients, x):
    return sum(coef * value for coef, value in zip(coefficients, x))


def variance_rank_features(rows, max_features):
    if not rows:
        return []
    feature_count = len(rows[0]["features"])
    scored = []
    for index in range(feature_count):
        values = [row["features"][index] for row in rows]
        if len(set(values)) <= 1:
            continue
        mean = sum(values) / len(values)
        variance = sum((value - mean) ** 2 for value in values) / len(values)
        scored.append((variance, index))
    scored.sort(reverse=True)
    return [index for _variance, index in scored[:max_features]]


def ridge_eval(rows, selected_indexes, ridge, holdout_mode):
    if not rows:
        return None
    errors = []
    if holdout_mode == "same_data":
        train_x, eval_x = standardize(rows, rows, selected_indexes)
        train_rows = [{**row, "x": x} for row, x in zip(rows, train_x)]
        eval_rows = [{**row, "x": x} for row, x in zip(rows, eval_x)]
        coeffs = fit_ridge(train_rows, len(selected_indexes) + 1, ridge)
        if coeffs is None:
            return None
        errors = [abs(row["rpm"] - predict(coeffs, row["x"])) for row in eval_rows]
    elif holdout_mode == "leave_source_out":
        for source in sorted({row["source_file"] for row in rows}):
            train = [row for row in rows if row["source_file"] != source]
            eval_set = [row for row in rows if row["source_file"] == source]
            if not train or not eval_set:
                continue
            train_x, eval_x = standardize(train, eval_set, selected_indexes)
            train_rows = [{**row, "x": x} for row, x in zip(train, train_x)]
            eval_rows = [{**row, "x": x} for row, x in zip(eval_set, eval_x)]
            coeffs = fit_ridge(train_rows, len(selected_indexes) + 1, ridge)
            if coeffs is None:
                continue
            errors.extend(abs(row["rpm"] - predict(coeffs, row["x"])) for row in eval_rows)
    else:
        raise ValueError(f"unknown holdout mode {holdout_mode}")
    return score_errors(errors)


def payload_lookup_eval(rows, mode):
    errors = []
    if mode == "same_data":
        by_key = defaultdict(list)
        for row in rows:
            by_key[row["key"]].append(row["rpm"])
        for row in rows:
            values = sorted(by_key[row["key"]])
            pred = values[len(values) // 2]
            errors.append(abs(row["rpm"] - pred))
        return {
            "unique_keys": len(by_key),
            "same_key_predictions": len(rows),
            **score_errors(errors),
        }
    if mode == "leave_one_out":
        same_key_predictions = 0
        for index, row in enumerate(rows):
            train = [other for i, other in enumerate(rows) if i != index]
            same = [other["rpm"] for other in train if other["key"] == row["key"]]
            if same:
                same_key_predictions += 1
                values = sorted(same)
                pred = values[len(values) // 2]
            else:
                pred = min(train, key=lambda other: key_distance(row["key"], other["key"]))["rpm"]
            errors.append(abs(row["rpm"] - pred))
        return {
            "unique_keys": len({row["key"] for row in rows}),
            "same_key_predictions": same_key_predictions,
            **score_errors(errors),
        }
    if mode == "leave_source_out":
        same_key_predictions = 0
        for row in rows:
            train = [other for other in rows if other["source_file"] != row["source_file"]]
            if not train:
                continue
            same = [other["rpm"] for other in train if other["key"] == row["key"]]
            if same:
                same_key_predictions += 1
                values = sorted(same)
                pred = values[len(values) // 2]
            else:
                pred = min(train, key=lambda other: key_distance(row["key"], other["key"]))["rpm"]
            errors.append(abs(row["rpm"] - pred))
        return {
            "unique_keys": len({row["key"] for row in rows}),
            "same_key_predictions": same_key_predictions,
            **score_errors(errors),
        }
    raise ValueError(f"unknown mode {mode}")


def key_distance(left, right):
    total = 0
    for left_part, right_part in zip(left, right):
        if left_part[:3] != right_part[:3]:
            total += 1000000
            continue
        left_bytes = parse_bytes(left_part[3])
        right_bytes = parse_bytes(right_part[3])
        total += sum((a - b) * (a - b) for a, b in zip(left_bytes, right_bytes))
    return total


def run_configs(truth, frames):
    configs = [
        {
            "name": "0x301_history",
            "ids": ["0x301"],
            "offsets": [-200, -150, -100, -70, -40, 0, 40],
            "max_distance_ms": 30,
        },
        {
            "name": "0x301_0x302_history",
            "ids": ["0x301", "0x302"],
            "offsets": [-150, -100, -70, -40, 0, 40],
            "max_distance_ms": 30,
        },
        {
            "name": "0x301_0x302_0x542_history",
            "ids": ["0x301", "0x302", "0x542"],
            "offsets": [-120, -80, -40, 0, 40],
            "max_distance_ms": 35,
        },
    ]
    ridge_rows = []
    lookup_rows = []
    for config in configs:
        feature_names, rows = build_sequence_dataset(
            truth,
            frames,
            config["ids"],
            config["offsets"],
            config["max_distance_ms"],
        )
        key_rows = payload_key_dataset(
            truth,
            frames,
            config["ids"],
            config["offsets"],
            config["max_distance_ms"],
        )
        selected = variance_rank_features(rows, min(80, len(feature_names)))
        for ridge in (0.1, 1.0, 10.0, 100.0, 1000.0):
            for mode in ("same_data", "leave_source_out"):
                score = ridge_eval(rows, selected, ridge, mode)
                if score is None:
                    continue
                ridge_rows.append({
                    "config": config["name"],
                    "ids": " ".join(config["ids"]),
                    "offsets": " ".join(str(value) for value in config["offsets"]),
                    "feature_rows": len(rows),
                    "selected_features": len(selected),
                    "ridge": ridge,
                    "mode": mode,
                    **score,
                })
        for mode in ("same_data", "leave_one_out", "leave_source_out"):
            score = payload_lookup_eval(key_rows, mode)
            lookup_rows.append({
                "config": config["name"],
                "ids": " ".join(config["ids"]),
                "offsets": " ".join(str(value) for value in config["offsets"]),
                "mode": mode,
                **score,
            })
    ridge_rows.sort(key=lambda row: (row["mode"] != "same_data", row["mae"], row["max_abs_err"]))
    lookup_rows.sort(key=lambda row: (row["mode"] != "same_data", row["mae"], row["max_abs_err"]))
    return ridge_rows, lookup_rows


def write_report(path, ridge_rows, lookup_rows):
    best_ridge_same = min((row for row in ridge_rows if row["mode"] == "same_data"), key=lambda row: row["mae"], default=None)
    best_ridge_holdout = min((row for row in ridge_rows if row["mode"] == "leave_source_out"), key=lambda row: row["mae"], default=None)
    best_lookup_same = min((row for row in lookup_rows if row["mode"] == "same_data"), key=lambda row: row["mae"], default=None)
    best_lookup_holdout = min((row for row in lookup_rows if row["mode"] == "leave_source_out"), key=lambda row: row["mae"], default=None)
    with path.open("w") as handle:
        handle.write("# Passive RPM Sequence Search\n\n")
        handle.write("OBD RPM rows are validation truth only; all candidate features come from passive CAN IDs.\n\n")
        handle.write("## Summary\n\n")
        if best_ridge_same:
            handle.write(
                f"- Best same-data ridge model: `{best_ridge_same['config']}`, MAE "
                f"`{best_ridge_same['mae']:.2f}`, P90 `{best_ridge_same['p90_abs_err']:.2f}`, "
                f"max `{best_ridge_same['max_abs_err']:.2f}`, under 10 rpm "
                f"`{best_ridge_same['under_10']}/{best_ridge_same['n']}`.\n"
            )
        if best_ridge_holdout:
            handle.write(
                f"- Best leave-source-out ridge model: `{best_ridge_holdout['config']}`, MAE "
                f"`{best_ridge_holdout['mae']:.2f}`, P90 `{best_ridge_holdout['p90_abs_err']:.2f}`, "
                f"max `{best_ridge_holdout['max_abs_err']:.2f}`, under 10 rpm "
                f"`{best_ridge_holdout['under_10']}/{best_ridge_holdout['n']}`.\n"
            )
        if best_lookup_same:
            handle.write(
                f"- Best same-data sequence lookup: `{best_lookup_same['config']}`, MAE "
                f"`{best_lookup_same['mae']:.2f}`, max `{best_lookup_same['max_abs_err']:.2f}`, "
                f"under 10 rpm `{best_lookup_same['under_10']}/{best_lookup_same['n']}`.\n"
            )
        if best_lookup_holdout:
            handle.write(
                f"- Best leave-source-out sequence lookup: `{best_lookup_holdout['config']}`, MAE "
                f"`{best_lookup_holdout['mae']:.2f}`, P90 `{best_lookup_holdout['p90_abs_err']:.2f}`, "
                f"max `{best_lookup_holdout['max_abs_err']:.2f}`, under 10 rpm "
                f"`{best_lookup_holdout['under_10']}/{best_lookup_holdout['n']}`.\n"
            )
        handle.write("\nNo sequence-aware passive model in this run proves a general `<10 rpm` decoder.\n\n")
        handle.write("## Generated Files\n\n")
        handle.write("- `sequence_ridge_scores.csv`\n")
        handle.write("- `sequence_lookup_scores.csv`\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    args = parser.parse_args()

    truth, frames = load_data(args.input)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    ridge_rows, lookup_rows = run_configs(truth, frames)

    ridge_fields = [
        "config", "ids", "offsets", "feature_rows", "selected_features", "ridge", "mode",
        "n", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10",
    ]
    lookup_fields = [
        "config", "ids", "offsets", "mode", "unique_keys", "same_key_predictions",
        "n", "mae", "median_abs_err", "p90_abs_err", "max_abs_err", "under_10",
    ]
    write_csv(args.out_dir / "sequence_ridge_scores.csv", ridge_rows, ridge_fields)
    write_csv(args.out_dir / "sequence_lookup_scores.csv", lookup_rows, lookup_fields)
    write_report(args.out_dir / "passive_rpm_sequence_search_report.md", ridge_rows, lookup_rows)

    print(f"truth_samples={len(truth)}")
    print(f"out_dir={args.out_dir}")
    if ridge_rows:
        best_holdout = min((row for row in ridge_rows if row["mode"] == "leave_source_out"), key=lambda row: row["mae"], default=None)
        if best_holdout:
            print(
                f"best_holdout_ridge={best_holdout['config']} mae={best_holdout['mae']:.3f} "
                f"max={best_holdout['max_abs_err']:.3f} under10={best_holdout['under_10']}/{best_holdout['n']}"
            )
    if lookup_rows:
        best_holdout = min((row for row in lookup_rows if row["mode"] == "leave_source_out"), key=lambda row: row["mae"], default=None)
        if best_holdout:
            print(
                f"best_holdout_lookup={best_holdout['config']} mae={best_holdout['mae']:.3f} "
                f"max={best_holdout['max_abs_err']:.3f} under10={best_holdout['under_10']}/{best_holdout['n']}"
            )


if __name__ == "__main__":
    main()
