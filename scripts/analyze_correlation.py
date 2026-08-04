#!/usr/bin/env python3
import csv
import math
import os
from bisect import bisect_left
from collections import Counter, defaultdict


INPUT = "analysis/final_correlation/d400_correlation_combined.csv"
OUT_DIR = "analysis/final_correlation"
WINDOW_BEFORE_MS = 250
WINDOW_AFTER_MS = 120
OVERFLOW_WINDOW_MS = 250
MIN_SAMPLES = 24

OBD_RESPONSE_IDS = {f"0x{value:x}" for value in range(0x7E8, 0x7F0)}
OBD_RESPONSE_IDS.update({f"0x{value:X}" for value in range(0x7E8, 0x7F0)})


def parse_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def parse_int(value):
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def parse_data_hex(data_hex):
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


def features_from_bytes(data):
    features = {}
    for i, byte in enumerate(data[:8]):
        features[f"b{i}"] = byte
        features[f"b{i}_hi"] = (byte >> 4) & 0x0F
        features[f"b{i}_lo"] = byte & 0x0F
    for i in range(min(len(data) - 1, 7)):
        be = (data[i] << 8) | data[i + 1]
        le = (data[i + 1] << 8) | data[i]
        features[f"be16_{i}_{i+1}"] = be
        features[f"le16_{i+1}_{i}"] = le
        features[f"sbe16_{i}_{i+1}"] = signed16(be)
        features[f"sle16_{i+1}_{i}"] = signed16(le)
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


def percentile(values, p):
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = int(round((len(ordered) - 1) * p))
    return ordered[index]


def pearson(xs, ys):
    if len(xs) < 2:
        return float("nan")
    mx = mean(xs)
    my = mean(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return float("nan")
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return cov / math.sqrt(vx * vy)


def linear_fit(xs, ys):
    mx = mean(xs)
    my = mean(ys)
    denom = sum((x - mx) ** 2 for x in xs)
    if denom <= 0:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / denom
    intercept = my - slope * mx
    preds = [slope * x + intercept for x in xs]
    residuals = [y - pred for y, pred in zip(ys, preds)]
    abs_errors = [abs(err) for err in residuals]
    ss_tot = sum((y - my) ** 2 for y in ys)
    ss_res = sum(err ** 2 for err in residuals)
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else float("nan")
    rmse = math.sqrt(ss_res / len(xs))
    return {
        "slope": slope,
        "intercept": intercept,
        "r2": r2,
        "mae": mean(abs_errors),
        "med_abs_err": median(abs_errors),
        "p90_abs_err": percentile(abs_errors, 0.90),
        "rmse": rmse,
    }


def score_samples(samples):
    xs = [sample["x"] for sample in samples]
    ys = [sample["y"] for sample in samples]
    fit = linear_fit(xs, ys)
    if fit is None:
        return None
    r = pearson(xs, ys)
    files = {sample["source_file"] for sample in samples}
    return {
        "n": len(samples),
        "files": len(files),
        "unique_x": len(set(xs)),
        "x_min": min(xs),
        "x_median": median(xs),
        "x_max": max(xs),
        "y_min": min(ys),
        "y_median": median(ys),
        "y_max": max(ys),
        "pearson_r": r,
        "abs_r": abs(r) if not math.isnan(r) else float("nan"),
        **fit,
    }


def safe(value, decimals=6):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return ""
    if isinstance(value, float):
        return f"{value:.{decimals}f}"
    return str(value)


def load_rows():
    by_file = defaultdict(lambda: {"frames": [], "obd": [], "events": [], "summary": []})
    with open(INPUT, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            source = row["source_file"]
            row_type = row["type"]
            ms = parse_int(row["ms"])
            if ms is None:
                continue
            row["ms_int"] = ms
            if row_type == "F":
                if row["id_hex"] in OBD_RESPONSE_IDS:
                    continue
                data = parse_data_hex(row["data_hex"])
                if not data:
                    continue
                row["bytes"] = data
                by_file[source]["frames"].append(row)
            elif row_type == "O":
                if row["ok"] != "1":
                    continue
                value = parse_float(row["value"])
                if value is None:
                    continue
                row["value_float"] = value
                by_file[source]["obd"].append(row)
            elif row_type == "E":
                by_file[source]["events"].append(row)
            elif row_type == "S":
                by_file[source]["summary"].append(row)
    return by_file


def has_near_overflow(events_ms, ms):
    left = bisect_left(events_ms, ms - OVERFLOW_WINDOW_MS)
    return left < len(events_ms) and events_ms[left] <= ms + OVERFLOW_WINDOW_MS


def nearest_frames_by_id(frames, times, ms):
    left = bisect_left(times, ms - WINDOW_BEFORE_MS)
    right = bisect_left(times, ms + WINDOW_AFTER_MS + 1)
    best = {}
    for frame in frames[left:right]:
        distance = abs(frame["ms_int"] - ms)
        key = frame["id_hex"].lower()
        current = best.get(key)
        if current is None or distance < current[0]:
            best[key] = (distance, frame)
    return [item[1] for item in best.values()]


def build_samples(by_file):
    obd_truth_rows = []
    candidate_samples = defaultdict(list)
    truth_counts = Counter()
    clean_counts = Counter()

    for source, data in by_file.items():
        frames = sorted(data["frames"], key=lambda row: row["ms_int"])
        frame_times = [row["ms_int"] for row in frames]
        events_ms = sorted(row["ms_int"] for row in data["events"])

        for obd in data["obd"]:
            metric = obd["pid_name"]
            target = obd["value_float"]
            ms = obd["ms_int"]
            clean = not has_near_overflow(events_ms, ms)
            truth_counts[metric] += 1
            if clean:
                clean_counts[metric] += 1

            truth = {
                "source_file": source,
                "source_row": obd["source_row"],
                "ms": obd["ms"],
                "session_ms": obd["session_ms"],
                "stage": obd["stage"],
                "pid_hex": obd["pid_hex"],
                "pid_name": metric,
                "value": obd["value"],
                "unit": obd["unit"],
                "raw_hex": obd["raw_hex"],
                "clean_window": "1" if clean else "0",
                "near_overflow": "0" if clean else "1",
            }
            obd_truth_rows.append(truth)

            for frame in nearest_frames_by_id(frames, frame_times, ms):
                features = features_from_bytes(frame["bytes"])
                for feature_name, feature_value in features.items():
                    key = (metric, frame["id_hex"].lower(), feature_name)
                    candidate_samples[key].append({
                        "x": float(feature_value),
                        "y": target,
                        "source_file": source,
                        "ms": ms,
                        "clean": clean,
                    })

    return obd_truth_rows, candidate_samples, truth_counts, clean_counts


def write_obd_truth(rows):
    path = os.path.join(OUT_DIR, "obd_truth_samples.csv")
    fields = [
        "source_file", "source_row", "ms", "session_ms", "stage",
        "pid_hex", "pid_name", "value", "unit", "raw_hex",
        "clean_window", "near_overflow",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    return path


def write_scores(candidate_samples):
    rows = []
    for (metric, can_id, feature), samples in candidate_samples.items():
        if len(samples) < MIN_SAMPLES:
            continue
        all_score = score_samples(samples)
        clean_samples = [sample for sample in samples if sample["clean"]]
        clean_score = score_samples(clean_samples) if len(clean_samples) >= MIN_SAMPLES else None
        if all_score is None:
            continue

        score = {
            "metric": metric,
            "id_hex": can_id,
            "feature": feature,
        }
        for prefix, result in (("all", all_score), ("clean", clean_score)):
            if result is None:
                for key in ["n", "files", "unique_x", "x_min", "x_median", "x_max", "y_min", "y_median", "y_max", "pearson_r", "abs_r", "slope", "intercept", "r2", "mae", "med_abs_err", "p90_abs_err", "rmse"]:
                    score[f"{prefix}_{key}"] = ""
            else:
                for key, value in result.items():
                    score[f"{prefix}_{key}"] = value
        rows.append(score)

    rows.sort(key=lambda row: (
        row.get("clean_r2") if isinstance(row.get("clean_r2"), float) else row.get("all_r2", -999),
        -(row.get("clean_mae") if isinstance(row.get("clean_mae"), float) else row.get("all_mae", 1e9)),
        row.get("clean_unique_x") if isinstance(row.get("clean_unique_x"), int) else row.get("all_unique_x", 0),
    ), reverse=True)

    fields = [
        "metric", "id_hex", "feature",
        "all_n", "all_files", "all_unique_x", "all_x_min", "all_x_median", "all_x_max",
        "all_y_min", "all_y_median", "all_y_max", "all_pearson_r", "all_abs_r",
        "all_slope", "all_intercept", "all_r2", "all_mae", "all_med_abs_err",
        "all_p90_abs_err", "all_rmse",
        "clean_n", "clean_files", "clean_unique_x", "clean_x_min", "clean_x_median", "clean_x_max",
        "clean_y_min", "clean_y_median", "clean_y_max", "clean_pearson_r", "clean_abs_r",
        "clean_slope", "clean_intercept", "clean_r2", "clean_mae", "clean_med_abs_err",
        "clean_p90_abs_err", "clean_rmse",
    ]

    combined_path = os.path.join(OUT_DIR, "passive_candidate_scores.csv")
    with open(combined_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: safe(row.get(field)) for field in fields})

    metric_paths = {}
    by_metric = defaultdict(list)
    for row in rows:
        by_metric[row["metric"]].append(row)
    for metric, metric_rows in by_metric.items():
        path = os.path.join(OUT_DIR, f"{metric}_candidate_scores.csv")
        metric_paths[metric] = path
        with open(path, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            for row in metric_rows:
                writer.writerow({field: safe(row.get(field)) for field in fields})
    return combined_path, metric_paths, rows


def tps_validation(candidate_samples):
    samples = candidate_samples.get(("tps", "0x301", "b2"), [])
    path = os.path.join(OUT_DIR, "tps_validation.csv")
    expected_idle = 27.0 * 100.0 / 255.0
    expected_slope = (100.0 - expected_idle) / 255.0
    rows = []
    errors = []
    for sample in samples:
        raw = sample["x"]
        expected = expected_idle + raw * expected_slope
        err = sample["y"] - expected
        errors.append(abs(err))
        rows.append({
            "source_file": sample["source_file"],
            "ms": sample["ms"],
            "clean_window": "1" if sample["clean"] else "0",
            "passive_0x301_b2_raw": int(raw),
            "obd_tps_pct": f"{sample['y']:.4f}",
            "formula_tps_pct": f"{expected:.4f}",
            "error_obd_minus_formula": f"{err:.4f}",
        })
    with open(path, "w", newline="") as f:
        fields = ["source_file", "ms", "clean_window", "passive_0x301_b2_raw", "obd_tps_pct", "formula_tps_pct", "error_obd_minus_formula"]
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        "n": len(rows),
        "expected_idle": expected_idle,
        "expected_slope": expected_slope,
        "mae": mean(errors) if errors else float("nan"),
        "median_abs_err": median(errors),
        "p90_abs_err": percentile(errors, 0.90),
        "max_abs_err": max(errors) if errors else float("nan"),
    }
    return path, summary


def write_notes(rows, metric_paths, truth_counts, clean_counts, tps_summary):
    notes_path = os.path.join(OUT_DIR, "metric_decode_notes.md")
    by_metric = defaultdict(list)
    for row in rows:
        by_metric[row["metric"]].append(row)

    priority = ["rpm", "tps", "map", "coolant", "iat", "ecu_voltage", "speed"]
    with open(notes_path, "w") as f:
        f.write("# Passive Decode Candidate Notes\n\n")
        f.write("This analysis uses OBD PID rows as truth and scores nearby passive CAN values from scratch.\n")
        f.write(f"Window: -{WINDOW_BEFORE_MS} ms / +{WINDOW_AFTER_MS} ms around each OBD sample. OBD response IDs 0x7E8-0x7EF are excluded.\n")
        f.write(f"Clean windows exclude OBD samples with MCP overflow events within +/- {OVERFLOW_WINDOW_MS} ms.\n\n")
        f.write("## OBD Truth Counts\n\n")
        for metric in sorted(truth_counts):
            f.write(f"- `{metric}`: total `{truth_counts[metric]}`, clean `{clean_counts[metric]}`\n")
        f.write("\n## TPS Formula Validation\n\n")
        f.write("Expected formula: `tps_abs_pct = 10.588235 + raw_0x301_b2 * 0.350634`.\n\n")
        f.write(f"- Samples: `{tps_summary['n']}`\n")
        f.write(f"- MAE: `{tps_summary['mae']:.4f}` percentage points\n")
        f.write(f"- Median abs error: `{tps_summary['median_abs_err']:.4f}`\n")
        f.write(f"- P90 abs error: `{tps_summary['p90_abs_err']:.4f}`\n")
        f.write(f"- Max abs error: `{tps_summary['max_abs_err']:.4f}`\n\n")

        f.write("## Top Candidates By Metric\n\n")
        for metric in priority:
            metric_rows = by_metric.get(metric, [])
            if not metric_rows:
                continue
            f.write(f"### {metric}\n\n")
            f.write(f"Candidate table: `{os.path.relpath(metric_paths[metric], OUT_DIR)}`\n\n")
            f.write("| rank | id | feature | clean n | clean r2 | clean mae | slope | intercept | unique x |\n")
            f.write("|---:|---|---|---:|---:|---:|---:|---:|---:|\n")
            for rank, row in enumerate(metric_rows[:12], start=1):
                f.write(
                    f"| {rank} | `{row['id_hex']}` | `{row['feature']}` | "
                    f"{safe(row.get('clean_n'), 0) or safe(row.get('all_n'), 0)} | "
                    f"{safe(row.get('clean_r2')) or safe(row.get('all_r2'))} | "
                    f"{safe(row.get('clean_mae')) or safe(row.get('all_mae'))} | "
                    f"{safe(row.get('clean_slope')) or safe(row.get('all_slope'))} | "
                    f"{safe(row.get('clean_intercept')) or safe(row.get('all_intercept'))} | "
                    f"{safe(row.get('clean_unique_x'), 0) or safe(row.get('all_unique_x'), 0)} |\n"
                )
            f.write("\n")
    return notes_path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    by_file = load_rows()
    truth_rows, candidate_samples, truth_counts, clean_counts = build_samples(by_file)
    truth_path = write_obd_truth(truth_rows)
    scores_path, metric_paths, score_rows = write_scores(candidate_samples)
    tps_path, tps_summary = tps_validation(candidate_samples)
    notes_path = write_notes(score_rows, metric_paths, truth_counts, clean_counts, tps_summary)

    print(f"truth={truth_path}")
    print(f"scores={scores_path}")
    print(f"tps_validation={tps_path}")
    print(f"notes={notes_path}")
    print(f"candidate_rows={len(score_rows)}")


if __name__ == "__main__":
    main()
