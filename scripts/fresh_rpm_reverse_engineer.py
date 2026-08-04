#!/usr/bin/env python3
"""Fresh RPM reverse-engineering pass from the combined D400 CSV.

This script intentionally does not import the existing project analyzers. It
uses the ordered correlation CSV only, extracts OBD PID 0x0C rows as truth, and
scores CAN-frame bytes in +/- row windows around those truth samples.
"""

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path


DEFAULT_INPUT = Path("analysis/final_correlation/d400_correlation_combined.csv")
DEFAULT_OUT_DIR = Path("analysis/final_correlation/fresh_rpm_decode")
OBD_RESPONSE_IDS = {f"0x{value:x}" for value in range(0x7E8, 0x7F0)}


def parse_int(value):
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def parse_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_bytes(data_hex):
    if not data_hex:
        return []
    out = []
    for part in data_hex.split():
        try:
            out.append(int(part, 16))
        except ValueError:
            return []
    return out


def signed16(value):
    return value - 0x10000 if value & 0x8000 else value


def feature_values(data):
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

    for width in (3, 4):
        limit = min(len(data) - width + 1, 8 - width + 1)
        for index in range(max(0, limit)):
            be = 0
            le = 0
            for offset, byte in enumerate(data[index:index + width]):
                be = (be << 8) | byte
                le |= byte << (8 * offset)
            features[f"be{width * 8}_{index}_{index + width - 1}"] = be
            features[f"le{width * 8}_{index + width - 1}_{index}"] = le

    return features


def mean(values):
    return sum(values) / len(values) if values else float("nan")


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
    index = int(round((len(ordered) - 1) * fraction))
    return ordered[index]


def linear_fit(xs, ys):
    if len(xs) < 2 or len(set(xs)) < 2:
        return None
    x_mean = mean(xs)
    y_mean = mean(ys)
    denom = sum((x - x_mean) ** 2 for x in xs)
    if denom <= 0:
        return None
    slope = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denom
    intercept = y_mean - slope * x_mean
    return score_prediction(ys, [slope * x + intercept for x in xs], {
        "slope": slope,
        "intercept": intercept,
    })


def through_origin_fit(xs, ys):
    denom = sum(x * x for x in xs)
    if denom <= 0:
        return None
    scale = sum(x * y for x, y in zip(xs, ys)) / denom
    return score_prediction(ys, [scale * x for x in xs], {
        "slope": scale,
        "intercept": 0.0,
    })


def score_prediction(ys, preds, extra=None):
    if not ys:
        return None
    errors = [y - pred for y, pred in zip(ys, preds)]
    abs_errors = [abs(error) for error in errors]
    y_mean = mean(ys)
    ss_tot = sum((y - y_mean) ** 2 for y in ys)
    ss_res = sum(error * error for error in errors)
    result = {
        "n": len(ys),
        "mae": mean(abs_errors),
        "median_abs_err": median(abs_errors),
        "p90_abs_err": percentile(abs_errors, 0.90),
        "max_abs_err": max(abs_errors),
        "rmse": math.sqrt(ss_res / len(ys)),
        "r2": 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan"),
        "under_10": sum(1 for error in abs_errors if error <= 10.0),
    }
    if extra:
        result.update(extra)
    return result


def fmt(value, decimals=6):
    if value is None:
        return ""
    if isinstance(value, float):
        if math.isnan(value):
            return ""
        return f"{value:.{decimals}f}"
    return str(value)


def load_rows(path):
    rows = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for index, row in enumerate(reader):
            row["_global_index"] = index
            row["_source_row_int"] = parse_int(row.get("source_row"))
            row["_ms_int"] = parse_int(row.get("ms"))
            row["_value_float"] = parse_float(row.get("value"))
            row["_bytes"] = parse_bytes(row.get("data_hex", "")) if row.get("type") == "F" else []
            rows.append(row)
    return rows


def group_by_source(rows):
    by_source = defaultdict(list)
    for row in rows:
        by_source[row["source_file"]].append(row)

    for source_rows in by_source.values():
        source_rows.sort(key=lambda row: (
            row["_source_row_int"] if row["_source_row_int"] is not None else 10**12,
            row["_global_index"],
        ))
        for position, row in enumerate(source_rows):
            row["_source_position"] = position
    return by_source


def rpm_truth_rows(rows):
    truth = []
    for row in rows:
        if row.get("type") != "O":
            continue
        if row.get("pid_name") != "rpm" or row.get("pid_hex", "").lower() != "0x0c":
            continue
        if row.get("ok") != "1" or row["_value_float"] is None:
            continue
        truth.append(row)
    return truth


def context_rows_for_window(truth_rows, by_source, window):
    output = []
    for truth in truth_rows:
        source_rows = by_source[truth["source_file"]]
        position = truth["_source_position"]
        start = max(0, position - window)
        stop = min(len(source_rows), position + window + 1)
        for row in source_rows[start:stop]:
            output.append({
                "window": window,
                "source_file": truth["source_file"],
                "obd_source_row": truth["source_row"],
                "obd_ms": truth["ms"],
                "obd_rpm": fmt(truth["_value_float"], 2),
                "relative_row": row["_source_position"] - position,
                "row_type": row.get("type", ""),
                "source_row": row.get("source_row", ""),
                "ms": row.get("ms", ""),
                "id_hex": row.get("id_hex", ""),
                "data_hex": row.get("data_hex", ""),
                "pid_hex": row.get("pid_hex", ""),
                "pid_name": row.get("pid_name", ""),
                "ok": row.get("ok", ""),
                "value": row.get("value", ""),
                "raw_hex": row.get("raw_hex", ""),
            })
    return output


def nearest_frames_by_id(truth, by_source, window):
    source_rows = by_source[truth["source_file"]]
    position = truth["_source_position"]
    start = max(0, position - window)
    stop = min(len(source_rows), position + window + 1)
    nearest = {}
    truth_ms = truth["_ms_int"] or 0

    for frame in source_rows[start:stop]:
        if frame.get("type") != "F" or not frame["_bytes"]:
            continue
        id_hex = frame.get("id_hex", "").lower()
        row_distance = abs(frame["_source_position"] - position)
        ms_distance = abs((frame["_ms_int"] or 0) - truth_ms)
        current = nearest.get(id_hex)
        if current is None or (row_distance, ms_distance) < current[0]:
            nearest[id_hex] = ((row_distance, ms_distance), frame)
    return nearest


def collect_feature_samples(truth_rows, by_source, window):
    samples = defaultdict(list)
    for truth in truth_rows:
        target = truth["_value_float"]
        for id_hex, ((row_distance, ms_distance), frame) in nearest_frames_by_id(truth, by_source, window).items():
            for feature, value in feature_values(frame["_bytes"]).items():
                samples[(id_hex, feature)].append({
                    "x": float(value),
                    "y": target,
                    "source_file": truth["source_file"],
                    "source_row": truth["source_row"],
                    "frame_source_row": frame["source_row"],
                    "row_distance": row_distance,
                    "ms_distance": ms_distance,
                    "data_hex": frame["data_hex"],
                })
    return samples


def score_feature_samples(samples, min_samples):
    rows = []
    for (id_hex, feature), values in samples.items():
        if len(values) < min_samples:
            continue
        xs = [sample["x"] for sample in values]
        ys = [sample["y"] for sample in values]
        fit = linear_fit(xs, ys)
        origin = through_origin_fit(xs, ys)
        if fit is None:
            continue
        rows.append({
            "id_hex": id_hex,
            "feature": feature,
            "n": len(values),
            "unique_x": len(set(xs)),
            "x_min": min(xs),
            "x_median": median(xs),
            "x_max": max(xs),
            "y_min": min(ys),
            "y_median": median(ys),
            "y_max": max(ys),
            "linear_slope": fit["slope"],
            "linear_intercept": fit["intercept"],
            "linear_r2": fit["r2"],
            "linear_mae": fit["mae"],
            "linear_p90_abs_err": fit["p90_abs_err"],
            "linear_max_abs_err": fit["max_abs_err"],
            "linear_under_10": fit["under_10"],
            "origin_slope": origin["slope"] if origin else "",
            "origin_mae": origin["mae"] if origin else "",
            "origin_p90_abs_err": origin["p90_abs_err"] if origin else "",
            "origin_max_abs_err": origin["max_abs_err"] if origin else "",
            "origin_under_10": origin["under_10"] if origin else "",
        })
    rows.sort(key=lambda row: (row["linear_mae"], row["linear_max_abs_err"], -row["linear_r2"]))
    return rows


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field, "") for field in fields})


def matrix_solve(a, b):
    n = len(b)
    aug = [list(a[row]) + [b[row]] for row in range(n)]
    for col in range(n):
        pivot = max(range(col, n), key=lambda row: abs(aug[row][col]))
        if abs(aug[pivot][col]) < 1e-12:
            return None
        if pivot != col:
            aug[col], aug[pivot] = aug[pivot], aug[col]
        pivot_value = aug[col][col]
        for item in range(col, n + 1):
            aug[col][item] /= pivot_value
        for row in range(n):
            if row == col:
                continue
            factor = aug[row][col]
            if factor == 0:
                continue
            for item in range(col, n + 1):
                aug[row][item] -= factor * aug[col][item]
    return [aug[row][n] for row in range(n)]


def linear_model(rows, targets, ridge=1e-6):
    if not rows:
        return None
    cols = len(rows[0])
    xtx = [[0.0 for _ in range(cols)] for _ in range(cols)]
    xty = [0.0 for _ in range(cols)]
    for xrow, target in zip(rows, targets):
        for i in range(cols):
            xty[i] += xrow[i] * target
            for j in range(cols):
                xtx[i][j] += xrow[i] * xrow[j]
    for i in range(cols):
        xtx[i][i] += ridge
    coeffs = matrix_solve(xtx, xty)
    if coeffs is None:
        return None
    preds = [sum(value * coeff for value, coeff in zip(xrow, coeffs)) for xrow in rows]
    return coeffs, score_prediction(targets, preds)


def score_multibyte_models(truth_rows, by_source, window):
    by_id = defaultdict(list)
    for truth in truth_rows:
        target = truth["_value_float"]
        for id_hex, ((row_distance, ms_distance), frame) in nearest_frames_by_id(truth, by_source, window).items():
            data = frame["_bytes"][:8]
            if not data:
                continue
            padded = data + [0] * (8 - len(data))
            by_id[id_hex].append({
                "bytes": padded,
                "target": target,
                "data_hex": frame["data_hex"],
            })

    output = []
    for id_hex, samples in by_id.items():
        if len(samples) < max(24, len(truth_rows) // 2):
            continue
        varying_indexes = []
        for index in range(8):
            if len({sample["bytes"][index] for sample in samples}) > 1:
                varying_indexes.append(index)
        if not varying_indexes:
            continue
        xrows = []
        targets = []
        for sample in samples:
            xrows.append([1.0] + [float(sample["bytes"][index]) for index in varying_indexes])
            targets.append(sample["target"])
        model = linear_model(xrows, targets)
        if model is None:
            continue
        coeffs, score = model
        formula_terms = [f"{coeffs[0]:.6g}"]
        for index, coeff in zip(varying_indexes, coeffs[1:]):
            formula_terms.append(f"{coeff:.6g}*b{index}")
        output.append({
            "id_hex": id_hex,
            "n": len(samples),
            "features": " ".join(f"b{index}" for index in varying_indexes),
            "formula": " + ".join(formula_terms),
            "r2": score["r2"],
            "mae": score["mae"],
            "p90_abs_err": score["p90_abs_err"],
            "max_abs_err": score["max_abs_err"],
            "under_10": score["under_10"],
        })
    output.sort(key=lambda row: (row["mae"], row["max_abs_err"], -row["r2"]))
    return output


def direct_obd_formula_trials(truth_rows, by_source, window):
    trials = [
        ("obd_7e8_be16_3_4_div4", lambda b: (((b[3] << 8) | b[4]) / 4.0) if len(b) >= 5 else None),
        ("obd_7e8_be16_3_4_raw", lambda b: float((b[3] << 8) | b[4]) if len(b) >= 5 else None),
        ("obd_7e8_be16_3_4_div2", lambda b: (((b[3] << 8) | b[4]) / 2.0) if len(b) >= 5 else None),
        ("obd_7e8_le16_4_3_div4", lambda b: (((b[4] << 8) | b[3]) / 4.0) if len(b) >= 5 else None),
        ("obd_7e8_high_byte_b3_times_64", lambda b: (b[3] * 64.0) if len(b) >= 4 else None),
        ("obd_7e8_low_byte_b4", lambda b: float(b[4]) if len(b) >= 5 else None),
    ]
    values = {name: {"truth": [], "pred": []} for name, _ in trials}

    for truth in truth_rows:
        nearest = nearest_frames_by_id(truth, by_source, window).get("0x7e8")
        if nearest is None:
            continue
        frame = nearest[1]
        data = frame["_bytes"]
        if len(data) < 5 or data[1] != 0x41 or data[2] != 0x0C:
            continue
        for name, func in trials:
            pred = func(data)
            if pred is None:
                continue
            values[name]["truth"].append(truth["_value_float"])
            values[name]["pred"].append(pred)

    rows = []
    for name, data in values.items():
        score = score_prediction(data["truth"], data["pred"])
        if score is None:
            continue
        rows.append({
            "trial": name,
            "n": score["n"],
            "mae": score["mae"],
            "median_abs_err": score["median_abs_err"],
            "p90_abs_err": score["p90_abs_err"],
            "max_abs_err": score["max_abs_err"],
            "rmse": score["rmse"],
            "r2": score["r2"],
            "under_10": score["under_10"],
        })
    rows.sort(key=lambda row: (row["mae"], row["max_abs_err"]))
    return rows


def exact_obd_validation_rows(truth_rows, by_source, window):
    rows = []
    for truth in truth_rows:
        nearest = nearest_frames_by_id(truth, by_source, window).get("0x7e8")
        if nearest is None:
            continue
        row_distance, ms_distance = nearest[0]
        frame = nearest[1]
        data = frame["_bytes"]
        if len(data) < 5 or data[1] != 0x41 or data[2] != 0x0C:
            continue
        raw = (data[3] << 8) | data[4]
        decoded = raw / 4.0
        expected = truth["_value_float"]
        abs_error = abs(expected - decoded)
        rows.append({
            "source_file": truth["source_file"],
            "obd_source_row": truth["source_row"],
            "obd_ms": truth["ms"],
            "obd_raw_hex": truth["raw_hex"],
            "obd_value_rpm": expected,
            "response_source_row": frame["source_row"],
            "response_ms": frame["ms"],
            "row_distance": row_distance,
            "ms_distance": ms_distance,
            "response_data_hex": frame["data_hex"],
            "byte_a": data[3],
            "byte_b": data[4],
            "decoded_raw_u16": raw,
            "decoded_rpm": decoded,
            "abs_error_rpm": abs_error,
            "under_10_rpm": "yes" if abs_error < 10.0 else "no",
        })
    return rows


def passive_formula_trials(truth_rows, by_source, window):
    trials = [
        ("0x301_b0_times_40", "0x301", lambda b: b[0] * 40.0 if len(b) >= 1 else None),
        ("0x301_b0_linear_39p58_plus_49p51", "0x301", lambda b: b[0] * 39.5826433 + 49.5112 if len(b) >= 1 else None),
        ("0x310_b4_times_100", "0x310", lambda b: b[4] * 100.0 if len(b) >= 5 else None),
        ("0x310_b5_times_100", "0x310", lambda b: b[5] * 100.0 if len(b) >= 6 else None),
        ("0x303_be16_3_4_div8", "0x303", lambda b: (((b[3] << 8) | b[4]) / 8.0) if len(b) >= 5 else None),
    ]
    values = {name: {"truth": [], "pred": []} for name, _, _ in trials}

    for truth in truth_rows:
        nearest_by_id = nearest_frames_by_id(truth, by_source, window)
        for name, id_hex, func in trials:
            nearest = nearest_by_id.get(id_hex)
            if nearest is None:
                continue
            pred = func(nearest[1]["_bytes"])
            if pred is None:
                continue
            values[name]["truth"].append(truth["_value_float"])
            values[name]["pred"].append(pred)

    rows = []
    for name, data in values.items():
        score = score_prediction(data["truth"], data["pred"])
        if score is None:
            continue
        rows.append({
            "trial": name,
            "n": score["n"],
            "mae": score["mae"],
            "median_abs_err": score["median_abs_err"],
            "p90_abs_err": score["p90_abs_err"],
            "max_abs_err": score["max_abs_err"],
            "rmse": score["rmse"],
            "r2": score["r2"],
            "under_10": score["under_10"],
        })
    rows.sort(key=lambda row: (row["mae"], row["max_abs_err"]))
    return rows


def repeated_value_spread(truth_rows, by_source, window, id_hex, key_func, label):
    groups = defaultdict(list)
    id_hex = id_hex.lower()
    for truth in truth_rows:
        nearest = nearest_frames_by_id(truth, by_source, window).get(id_hex)
        if nearest is None:
            continue
        frame = nearest[1]
        key = key_func(frame["_bytes"], frame)
        if key is None:
            continue
        groups[key].append(truth["_value_float"])

    rows = []
    for key, values in groups.items():
        if len(values) < 2:
            continue
        rows.append({
            "group_type": label,
            "key": key,
            "n": len(values),
            "rpm_min": min(values),
            "rpm_median": median(values),
            "rpm_max": max(values),
            "rpm_span": max(values) - min(values),
            "can_satisfy_all_under_10": "yes" if max(values) - min(values) <= 20.0 else "no",
        })
    rows.sort(key=lambda row: (row["rpm_span"], row["n"]), reverse=True)
    return rows


def write_report(
    path,
    input_path,
    truth_rows,
    score_outputs,
    formula_outputs,
    multibyte_outputs,
    spread_outputs,
    exact_validation,
):
    best_20 = score_outputs[20]["passive"][0] if score_outputs[20]["passive"] else None
    best_40 = score_outputs[40]["passive"][0] if score_outputs[40]["passive"] else None
    obd_best = formula_outputs[20]["obd"][0] if formula_outputs[20]["obd"] else None
    passive_simple = formula_outputs[20]["passive"][0] if formula_outputs[20]["passive"] else None
    passive_multibyte = [
        row for row in multibyte_outputs[20]
        if row["id_hex"].lower() not in OBD_RESPONSE_IDS
    ]
    multi_best = passive_multibyte[0] if passive_multibyte else None
    b0_spread = spread_outputs[20]["b0"][0] if spread_outputs[20]["b0"] else None
    frame_spread = spread_outputs[20]["frame"][0] if spread_outputs[20]["frame"] else None

    with path.open("w") as handle:
        handle.write("# Fresh RPM Reverse Engineering\n\n")
        handle.write(f"Input CSV: `{input_path}`\n\n")
        handle.write(f"Valid OBD RPM truth samples: `{len(truth_rows)}`. ")
        handle.write(
            f"Truth range: `{min(row['_value_float'] for row in truth_rows):.1f}` to "
            f"`{max(row['_value_float'] for row in truth_rows):.1f}` rpm.\n\n"
        )

        handle.write("## Exact OBD PID Decode\n\n")
        handle.write("For OBD response frames shaped like `04 41 0C A B ...` on `0x7e8`:\n\n")
        handle.write("```text\n")
        handle.write("rpm = ((A << 8) | B) / 4\n")
        handle.write("```\n\n")
        handle.write("In the combined CSV, the `raw_hex` column is already `0xAABB`, so the same formula is `rpm = int(raw_hex, 16) / 4`.\n\n")
        if obd_best:
            handle.write(
                f"Fresh check: `{obd_best['trial']}` matched `{obd_best['n']}` samples with "
                f"MAE `{obd_best['mae']:.3f}` rpm and max error `{obd_best['max_abs_err']:.3f}` rpm.\n\n"
            )
        if exact_validation:
            under_10 = sum(1 for row in exact_validation if row["under_10_rpm"] == "yes")
            max_error = max(row["abs_error_rpm"] for row in exact_validation)
            handle.write(
                f"Sample-by-sample validation file: `rpm_exact_obd_validation.csv`; "
                f"`{under_10}/{len(exact_validation)}` rows are under 10 rpm, "
                f"max error `{max_error:.3f}` rpm.\n\n"
            )

        handle.write("## Passive CAN Search\n\n")
        handle.write("OBD response IDs `0x7e8..0x7ef` were excluded for the passive search below.\n\n")
        handle.write("| window | best passive id/feature | linear formula | n | MAE | P90 | Max | <=10 rpm |\n")
        handle.write("|---:|---|---|---:|---:|---:|---:|---:|\n")
        for window, best in ((20, best_20), (40, best_40)):
            if not best:
                continue
            handle.write(
                f"| +/-{window} rows | `{best['id_hex']} {best['feature']}` | "
                f"`rpm = {best['linear_slope']:.6g} * raw + {best['linear_intercept']:.6g}` | "
                f"{best['n']} | {best['linear_mae']:.2f} | {best['linear_p90_abs_err']:.2f} | "
                f"{best['linear_max_abs_err']:.2f} | {best['linear_under_10']}/{best['n']} |\n"
            )
        handle.write("\n")

        if passive_simple:
            handle.write(
                f"The best practical passive trial is `{passive_simple['trial']}` with "
                f"MAE `{passive_simple['mae']:.2f}` rpm and max error "
                f"`{passive_simple['max_abs_err']:.2f}` rpm. It does not satisfy the less-than-10-rpm target for every OBD RPM sample.\n\n"
            )

        handle.write("## Why Passive Is Not Exact Here\n\n")
        if b0_spread:
            handle.write(
                f"Using the nearest `0x301` frame, repeated `b0` values map to widely different OBD RPM truths. "
                f"Worst case: `b0={b0_spread['key']}` appears `{b0_spread['n']}` times and spans "
                f"`{b0_spread['rpm_min']:.1f}` to `{b0_spread['rpm_max']:.1f}` rpm. "
                "Any deterministic formula using only `b0` would need that span to be <=20 rpm to keep every sample within 10 rpm.\n\n"
            )
        if frame_spread:
            handle.write(
                f"Even full repeated `0x301` payloads are ambiguous in the nearest-frame join. "
                f"Worst repeated payload `{frame_spread['key']}` spans "
                f"`{frame_spread['rpm_min']:.1f}` to `{frame_spread['rpm_max']:.1f}` rpm. "
                "That points to timing/quantization ambiguity, not just a missing endian conversion.\n\n"
            )
        if multi_best:
            handle.write(
                f"A training-only passive multi-byte linear model also fails the hard target. Best +/-20-row model: "
                f"`{multi_best['id_hex']}` using `{multi_best['features']}`, MAE `{multi_best['mae']:.2f}` rpm, "
                f"max error `{multi_best['max_abs_err']:.2f}` rpm.\n\n"
            )

        handle.write("## Conclusion\n\n")
        handle.write("- Exact formula for the actual OBD RPM PID response: `rpm = ((byte3 << 8) | byte4) / 4`.\n")
        handle.write("- Best passive broadcast candidate in this CSV: `0x301 b0`, approximately `rpm = 40 * b0`.\n")
        handle.write("- Increasing the context from +/-20 to +/-40 rows did not reveal a passive signal that meets <10 rpm on every OBD RPM sample.\n")
        handle.write("- If the dashboard needs <10 rpm error, use PID `0x0C` / `0x7e8` truth or capture a finer passive RPM signal; `0x301 b0` is useful for a passive tach estimate but is not exact enough.\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--windows", type=int, nargs="+", default=[20, 40])
    args = parser.parse_args()

    rows = load_rows(args.input)
    by_source = group_by_source(rows)
    truth = rpm_truth_rows(rows)
    if not truth:
        raise SystemExit("No successful OBD RPM rows found")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    score_outputs = {}
    formula_outputs = {}
    multibyte_outputs = {}
    spread_outputs = {}

    context_fields = [
        "window", "source_file", "obd_source_row", "obd_ms", "obd_rpm",
        "relative_row", "row_type", "source_row", "ms", "id_hex", "data_hex",
        "pid_hex", "pid_name", "ok", "value", "raw_hex",
    ]
    score_fields = [
        "id_hex", "feature", "n", "unique_x", "x_min", "x_median", "x_max",
        "y_min", "y_median", "y_max", "linear_slope", "linear_intercept",
        "linear_r2", "linear_mae", "linear_p90_abs_err", "linear_max_abs_err",
        "linear_under_10", "origin_slope", "origin_mae", "origin_p90_abs_err",
        "origin_max_abs_err", "origin_under_10",
    ]
    formula_fields = [
        "trial", "n", "mae", "median_abs_err", "p90_abs_err",
        "max_abs_err", "rmse", "r2", "under_10",
    ]
    exact_fields = [
        "source_file", "obd_source_row", "obd_ms", "obd_raw_hex",
        "obd_value_rpm", "response_source_row", "response_ms",
        "row_distance", "ms_distance", "response_data_hex", "byte_a",
        "byte_b", "decoded_raw_u16", "decoded_rpm", "abs_error_rpm",
        "under_10_rpm",
    ]
    multibyte_fields = [
        "id_hex", "n", "features", "formula", "r2", "mae",
        "p90_abs_err", "max_abs_err", "under_10",
    ]
    spread_fields = [
        "group_type", "key", "n", "rpm_min", "rpm_median", "rpm_max",
        "rpm_span", "can_satisfy_all_under_10",
    ]

    min_samples = max(24, len(truth) // 2)
    exact_validation = exact_obd_validation_rows(truth, by_source, 20)
    write_csv(args.out_dir / "rpm_exact_obd_validation.csv", exact_validation, exact_fields)

    for window in args.windows:
        context = context_rows_for_window(truth, by_source, window)
        write_csv(args.out_dir / f"rpm_context_window_{window}.csv", context, context_fields)

        feature_samples = collect_feature_samples(truth, by_source, window)
        all_scores = score_feature_samples(feature_samples, min_samples)
        passive_scores = [
            row for row in all_scores
            if row["id_hex"].lower() not in OBD_RESPONSE_IDS
        ]
        write_csv(args.out_dir / f"rpm_candidate_scores_window_{window}_all.csv", all_scores, score_fields)
        write_csv(args.out_dir / f"rpm_candidate_scores_window_{window}_passive.csv", passive_scores, score_fields)
        score_outputs[window] = {"all": all_scores, "passive": passive_scores}

        obd_trials = direct_obd_formula_trials(truth, by_source, window)
        passive_trials = passive_formula_trials(truth, by_source, window)
        write_csv(args.out_dir / f"rpm_formula_trials_window_{window}_obd.csv", obd_trials, formula_fields)
        write_csv(args.out_dir / f"rpm_formula_trials_window_{window}_passive.csv", passive_trials, formula_fields)
        formula_outputs[window] = {"obd": obd_trials, "passive": passive_trials}

        multibyte = score_multibyte_models(truth, by_source, window)
        write_csv(args.out_dir / f"rpm_multibyte_models_window_{window}.csv", multibyte, multibyte_fields)
        multibyte_outputs[window] = multibyte

        b0_spread = repeated_value_spread(
            truth, by_source, window, "0x301",
            lambda data, _frame: str(data[0]) if len(data) >= 1 else None,
            "0x301_b0",
        )
        frame_spread = repeated_value_spread(
            truth, by_source, window, "0x301",
            lambda _data, frame: frame.get("data_hex"),
            "0x301_data_hex",
        )
        write_csv(args.out_dir / f"rpm_0x301_b0_spread_window_{window}.csv", b0_spread, spread_fields)
        write_csv(args.out_dir / f"rpm_0x301_frame_spread_window_{window}.csv", frame_spread, spread_fields)
        spread_outputs[window] = {"b0": b0_spread, "frame": frame_spread}

    report_path = args.out_dir / "rpm_reverse_engineering_report.md"
    write_report(
        report_path,
        args.input,
        truth,
        score_outputs,
        formula_outputs,
        multibyte_outputs,
        spread_outputs,
        exact_validation,
    )

    print(f"truth_samples={len(truth)}")
    print(f"out_dir={args.out_dir}")
    print(f"report={report_path}")
    for window in args.windows:
        best_all = score_outputs[window]["all"][0]
        best_passive = score_outputs[window]["passive"][0]
        best_obd_formula = formula_outputs[window]["obd"][0]
        print(
            f"window={window} obd_formula={best_obd_formula['trial']} "
            f"obd_max_err={best_obd_formula['max_abs_err']:.3f}"
        )
        print(
            f"window={window} best_all={best_all['id_hex']} {best_all['feature']} "
            f"mae={best_all['linear_mae']:.3f} max={best_all['linear_max_abs_err']:.3f}"
        )
        print(
            f"window={window} best_passive={best_passive['id_hex']} {best_passive['feature']} "
            f"mae={best_passive['linear_mae']:.3f} max={best_passive['linear_max_abs_err']:.3f}"
        )


if __name__ == "__main__":
    main()
