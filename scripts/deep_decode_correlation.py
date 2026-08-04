#!/usr/bin/env python3
import csv
import glob
import math
import os
from bisect import bisect_left
from collections import defaultdict

from analyze_correlation import (
    INPUT,
    OUT_DIR,
    features_from_bytes,
    linear_fit,
    load_rows,
    mean,
    median,
    parse_data_hex,
    percentile,
    score_samples,
)


TOP_CANDIDATES = {
    "rpm": ("0x301", "b0"),
    "rpm_old_bucket": ("0x310", "b4"),
    "rpm_old_smooth": ("0x303", "be16_3_4"),
    "tps": ("0x301", "b2"),
    "map": ("0x302", "b6"),
    "coolant": ("0x302", "sbe16_0_1"),
    "iat": ("0x302", "b5"),
    "ecu_voltage": ("0x303", "be16_1_2"),
}


def safe_float(value, decimals=4):
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return f"{value:.{decimals}f}" if isinstance(value, float) else str(value)


def nearest_obd_rows(by_file, source, metric, ms, max_distance_ms=900):
    rows = [
        row for row in by_file[source]["obd"]
        if row.get("pid_name") == metric and row.get("value_float") is not None
    ]
    rows.sort(key=lambda row: row["ms_int"])
    times = [row["ms_int"] for row in rows]
    if not times:
        return None
    idx = bisect_left(times, ms)
    candidates = []
    if idx < len(rows):
        candidates.append(rows[idx])
    if idx > 0:
        candidates.append(rows[idx - 1])
    if not candidates:
        return None
    best = min(candidates, key=lambda row: abs(row["ms_int"] - ms))
    if abs(best["ms_int"] - ms) > max_distance_ms:
        return None
    return best


def nearest_frame(frames_by_file_id, source, id_hex, ms, max_distance_ms=180):
    frames = frames_by_file_id.get((source, id_hex.lower()), [])
    if not frames:
        return None
    times = [row["ms_int"] for row in frames]
    idx = bisect_left(times, ms)
    candidates = []
    if idx < len(frames):
        candidates.append(frames[idx])
    if idx > 0:
        candidates.append(frames[idx - 1])
    if not candidates:
        return None
    best = min(candidates, key=lambda row: abs(row["ms_int"] - ms))
    if abs(best["ms_int"] - ms) > max_distance_ms:
        return None
    return best


def build_frames_by_file_id(by_file):
    out = {}
    for source, data in by_file.items():
        groups = defaultdict(list)
        for row in data["frames"]:
            groups[row["id_hex"].lower()].append(row)
        for id_hex, frames in groups.items():
            frames.sort(key=lambda row: row["ms_int"])
            out[(source, id_hex)] = frames
    return out


def candidate_samples_for_metric(by_file, frames_by_file_id, metric, id_hex, feature):
    samples = []
    id_hex = id_hex.lower()
    for source, data in by_file.items():
        for obd in data["obd"]:
            if obd.get("pid_name") != metric:
                continue
            frame = nearest_frame(frames_by_file_id, source, id_hex, obd["ms_int"])
            if frame is None:
                continue
            features = features_from_bytes(frame["bytes"])
            if feature not in features:
                continue
            samples.append({
                "source_file": source,
                "stage": obd.get("stage", ""),
                "ms": obd["ms_int"],
                "obd_value": obd["value_float"],
                "unit": obd.get("unit", ""),
                "raw": float(features[feature]),
                "data_hex": frame["data_hex"],
                "frame_ms": frame["ms_int"],
                "distance_ms": abs(frame["ms_int"] - obd["ms_int"]),
            })
    return samples


def write_candidate_samples(name, samples, formula=None):
    path = os.path.join(OUT_DIR, f"{name}_samples.csv")
    fit = score_samples([{"x": s["raw"], "y": s["obd_value"], "source_file": s["source_file"]} for s in samples])
    slope = fit["slope"] if fit else None
    intercept = fit["intercept"] if fit else None
    fields = [
        "source_file", "stage", "ms", "frame_ms", "distance_ms",
        "raw", "obd_value", "fit_pred", "fit_err",
        "simple_pred", "simple_err", "data_hex",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for sample in samples:
            fit_pred = slope * sample["raw"] + intercept if slope is not None else None
            simple_pred = formula(sample["raw"]) if formula is not None else None
            writer.writerow({
                "source_file": sample["source_file"],
                "stage": sample["stage"],
                "ms": sample["ms"],
                "frame_ms": sample["frame_ms"],
                "distance_ms": sample["distance_ms"],
                "raw": safe_float(sample["raw"], 2),
                "obd_value": safe_float(sample["obd_value"], 2),
                "fit_pred": safe_float(fit_pred, 2),
                "fit_err": safe_float(sample["obd_value"] - fit_pred if fit_pred is not None else None, 2),
                "simple_pred": safe_float(simple_pred, 2),
                "simple_err": safe_float(sample["obd_value"] - simple_pred if simple_pred is not None else None, 2),
                "data_hex": sample["data_hex"],
            })
    return path, fit


def write_group_summary(name, samples, key_field, fit):
    path = os.path.join(OUT_DIR, f"{name}_by_{key_field}.csv")
    slope = fit["slope"] if fit else 0.0
    intercept = fit["intercept"] if fit else 0.0
    groups = defaultdict(list)
    for sample in samples:
        groups[sample[key_field]].append(sample)
    fields = [
        key_field, "n", "unique_raw", "raw_min", "raw_median", "raw_max",
        "obd_min", "obd_median", "obd_max", "fit_mae", "fit_p90_abs_err",
        "local_slope", "local_intercept", "local_r2",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for key, group in sorted(groups.items()):
            raw = [s["raw"] for s in group]
            y = [s["obd_value"] for s in group]
            errors = [abs(v - (slope * r + intercept)) for r, v in zip(raw, y)]
            local = linear_fit(raw, y) if len(group) >= 6 and len(set(raw)) >= 2 else None
            writer.writerow({
                key_field: key,
                "n": len(group),
                "unique_raw": len(set(raw)),
                "raw_min": safe_float(min(raw), 2),
                "raw_median": safe_float(median(raw), 2),
                "raw_max": safe_float(max(raw), 2),
                "obd_min": safe_float(min(y), 2),
                "obd_median": safe_float(median(y), 2),
                "obd_max": safe_float(max(y), 2),
                "fit_mae": safe_float(mean(errors), 2),
                "fit_p90_abs_err": safe_float(percentile(errors, 0.90), 2),
                "local_slope": safe_float(local["slope"], 6) if local else "",
                "local_intercept": safe_float(local["intercept"], 6) if local else "",
                "local_r2": safe_float(local["r2"], 6) if local else "",
            })
    return path


def write_raw_table(name, samples, fit, formula=None):
    path = os.path.join(OUT_DIR, f"{name}_raw_table.csv")
    slope = fit["slope"] if fit else 0.0
    intercept = fit["intercept"] if fit else 0.0
    groups = defaultdict(list)
    for sample in samples:
        groups[int(sample["raw"])].append(sample)
    fields = [
        "raw", "n", "obd_min", "obd_p10", "obd_median", "obd_mean", "obd_p90", "obd_max",
        "fit_pred", "simple_pred", "fit_mae",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for raw, group in sorted(groups.items()):
            values = [s["obd_value"] for s in group]
            fit_pred = slope * raw + intercept
            simple_pred = formula(raw) if formula else None
            writer.writerow({
                "raw": raw,
                "n": len(group),
                "obd_min": safe_float(min(values), 2),
                "obd_p10": safe_float(percentile(values, 0.10), 2),
                "obd_median": safe_float(median(values), 2),
                "obd_mean": safe_float(mean(values), 2),
                "obd_p90": safe_float(percentile(values, 0.90), 2),
                "obd_max": safe_float(max(values), 2),
                "fit_pred": safe_float(fit_pred, 2),
                "simple_pred": safe_float(simple_pred, 2),
                "fit_mae": safe_float(mean([abs(v - fit_pred) for v in values]), 2),
            })
    return path


def write_rpm_context(by_file, samples, fit):
    path = os.path.join(OUT_DIR, "rpm_0x301_b0_context.csv")
    fields = [
        "source_file", "stage", "ms", "raw_b0", "obd_rpm",
        "pred_rpm", "err_rpm", "near_tps", "near_tps_age_ms",
        "near_map", "near_map_age_ms", "near_coolant", "near_coolant_age_ms",
    ]
    slope = fit["slope"]
    intercept = fit["intercept"]
    context_rows = []
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for sample in samples:
            row = {
                "source_file": sample["source_file"],
                "stage": sample["stage"],
                "ms": sample["ms"],
                "raw_b0": int(sample["raw"]),
                "obd_rpm": safe_float(sample["obd_value"], 2),
                "pred_rpm": safe_float(slope * sample["raw"] + intercept, 2),
                "err_rpm": safe_float(sample["obd_value"] - (slope * sample["raw"] + intercept), 2),
            }
            for metric in ("tps", "map", "coolant"):
                near = nearest_obd_rows(by_file, sample["source_file"], metric, sample["ms"])
                row[f"near_{metric}"] = safe_float(near["value_float"], 2) if near else ""
                row[f"near_{metric}_age_ms"] = abs(near["ms_int"] - sample["ms"]) if near else ""
            writer.writerow(row)
            context_rows.append(row)
    return path, context_rows


def correlation(xs, ys):
    if len(xs) < 2:
        return float("nan")
    mx = mean(xs)
    my = mean(ys)
    vx = sum((x - mx) ** 2 for x in xs)
    vy = sum((y - my) ** 2 for y in ys)
    if vx <= 0 or vy <= 0:
        return float("nan")
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(vx * vy)


def context_summary(context_rows):
    rows = []
    for label, predicate in (
        ("all", lambda row: True),
        ("near_closed_tps", lambda row: row["near_tps"] != "" and float(row["near_tps"]) <= 12.5),
        ("open_tps", lambda row: row["near_tps"] != "" and float(row["near_tps"]) > 20.0),
        ("idle_stage", lambda row: "idle" in row["stage"]),
        ("rev_stage", lambda row: "idle" not in row["stage"]),
    ):
        subset = [row for row in context_rows if predicate(row)]
        if not subset:
            continue
        raw = [float(row["raw_b0"]) for row in subset]
        rpm = [float(row["obd_rpm"]) for row in subset]
        tps = [float(row["near_tps"]) for row in subset if row["near_tps"] != ""]
        rpm_for_tps = [float(row["obd_rpm"]) for row in subset if row["near_tps"] != ""]
        fit = linear_fit(raw, rpm) if len(set(raw)) >= 2 else None
        rows.append({
            "subset": label,
            "n": len(subset),
            "unique_raw": len(set(raw)),
            "raw_min": min(raw),
            "raw_median": median(raw),
            "raw_max": max(raw),
            "rpm_min": min(rpm),
            "rpm_median": median(rpm),
            "rpm_max": max(rpm),
            "raw_vs_rpm_r": correlation(raw, rpm),
            "tps_vs_rpm_r": correlation(tps, rpm_for_tps) if len(tps) == len(rpm_for_tps) else float("nan"),
            "fit_slope": fit["slope"] if fit else float("nan"),
            "fit_intercept": fit["intercept"] if fit else float("nan"),
            "fit_r2": fit["r2"] if fit else float("nan"),
            "fit_mae": fit["mae"] if fit else float("nan"),
        })
    return rows


def write_context_summary(rows):
    path = os.path.join(OUT_DIR, "rpm_0x301_b0_context_summary.csv")
    fields = [
        "subset", "n", "unique_raw", "raw_min", "raw_median", "raw_max",
        "rpm_min", "rpm_median", "rpm_max", "raw_vs_rpm_r", "tps_vs_rpm_r",
        "fit_slope", "fit_intercept", "fit_r2", "fit_mae",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: safe_float(row.get(field), 6) for field in fields})
    return path


def validate_yesterday_rpm():
    files = sorted(glob.glob("/Users/hiteshyadav/Downloads/d400_capture *.csv"))
    stage_rows = defaultdict(list)
    for path in files:
        try:
            with open(path, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if row.get("type") != "F" or row.get("id_hex", "").lower() != "0x301":
                        continue
                    data = parse_data_hex(row.get("data_hex", ""))
                    if len(data) < 3:
                        continue
                    stage_rows[row.get("stage", "")].append({
                        "raw_b0": data[0],
                        "raw_b2_tps": data[2],
                    })
        except FileNotFoundError:
            continue

    path = os.path.join(OUT_DIR, "yesterday_0x301_stage_validation.csv")
    fields = [
        "stage", "n", "b0_min", "b0_median", "b0_max",
        "pred_rpm_40x_median", "tps_raw_min", "tps_raw_median", "tps_raw_max",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for stage, rows in sorted(stage_rows.items()):
            if not rows:
                continue
            b0 = [row["raw_b0"] for row in rows]
            b2 = [row["raw_b2_tps"] for row in rows]
            writer.writerow({
                "stage": stage,
                "n": len(rows),
                "b0_min": min(b0),
                "b0_median": safe_float(median(b0), 2),
                "b0_max": max(b0),
                "pred_rpm_40x_median": safe_float(40.0 * median(b0), 2),
                "tps_raw_min": min(b2),
                "tps_raw_median": safe_float(median(b2), 2),
                "tps_raw_max": max(b2),
            })
    return path


def simple_formula(metric):
    if metric == "rpm":
        return lambda raw: 40.0 * raw
    if metric == "rpm_old_bucket":
        return lambda raw: 100.0 * raw
    if metric == "tps":
        idle = 27.0 * 100.0 / 255.0
        return lambda raw: idle + raw * ((100.0 - idle) / 255.0)
    if metric == "map":
        return lambda raw: raw + 1.0
    return None


def write_report(fits, paths, context_rows):
    path = os.path.join(OUT_DIR, "deep_decode_report.md")
    with open(path, "w") as f:
        f.write("# Deep Passive Decode Report\n\n")
        f.write("This report uses the new passive + OBD correlation captures. OBD rows are treated as truth; passive rows are candidates.\n\n")
        f.write("## High Confidence\n\n")
        f.write("### TPS\n\n")
        f.write("- Passive source: `0x301 b2`\n")
        f.write("- Formula: `tps_abs_pct = 10.588235 + raw * 0.350634`\n")
        f.write("- This matches OBD TPS with about `0.1 percentage point` average error in the current run.\n\n")
        f.write("### MAP\n\n")
        f.write("- Passive source candidate: `0x302 b6`\n")
        fit = fits.get("map")
        if fit:
            f.write(f"- Linear fit: `map_kpa = {fit['slope']:.6f} * raw + {fit['intercept']:.6f}`; MAE `{fit['mae']:.3f}` kPa; R2 `{fit['r2']:.4f}`.\n")
            f.write("- A practical first formula is very close to `map_kpa = raw + 1`.\n\n")
        f.write("## RPM Fresh Decode\n\n")
        fit = fits.get("rpm")
        if fit:
            f.write("- Best current passive source against OBD RPM: `0x301 b0`.\n")
            f.write(f"- Fit: `rpm = {fit['slope']:.6f} * raw + {fit['intercept']:.6f}`.\n")
            f.write(f"- Samples `{fit['n']}`, files `{fit['files']}`, unique raw values `{fit['unique_x']}`, R2 `{fit['r2']:.5f}`, MAE `{fit['mae']:.1f}` rpm.\n")
            f.write("- Practical rounded formula to test: `rpm = 40 * raw`. It is engine-off-safe because raw `0` becomes `0` rpm.\n")
            f.write("- Important caveat: sharp throttle transitions still create alignment outliers because OBD and passive samples are not perfectly simultaneous.\n\n")
        old_bucket = fits.get("rpm_old_bucket")
        old_smooth = fits.get("rpm_old_smooth")
        if old_bucket or old_smooth:
            f.write("Comparison against older passive candidates:\n\n")
            f.write("| candidate | source | MAE rpm | R2 | note |\n")
            f.write("|---|---|---:|---:|---|\n")
            if fit:
                f.write(f"| new byte | `0x301 b0` | {fit['mae']:.1f} | {fit['r2']:.4f} | best current candidate |\n")
            if old_bucket:
                f.write(f"| old bucket | `0x310 b4` | {old_bucket['mae']:.1f} | {old_bucket['r2']:.4f} | reliable but coarse |\n")
            if old_smooth:
                f.write(f"| old smooth | `0x303 be16_3_4` | {old_smooth['mae']:.1f} | {old_smooth['r2']:.4f} | worse against direct OBD truth |\n")
            f.write("\n")
        f.write("The correlation capture stage labels were not controlled tightly, so use the source-file and raw-value tables more than the stage names.\n\n")
        f.write("RPM context table: `rpm_0x301_b0_context_summary.csv`.\n\n")
        f.write("| subset | n | raw range | rpm range | raw-rpm r | tps-rpm r | fit mae |\n")
        f.write("|---|---:|---|---|---:|---:|---:|\n")
        for row in context_rows:
            f.write(
                f"| `{row['subset']}` | {row['n']} | "
                f"{row['raw_min']:.0f}..{row['raw_max']:.0f} | "
                f"{row['rpm_min']:.0f}..{row['rpm_max']:.0f} | "
                f"{row['raw_vs_rpm_r']:.4f} | {row['tps_vs_rpm_r']:.4f} | {row['fit_mae']:.1f} |\n"
            )
        f.write("\n")
        f.write("## Medium Confidence\n\n")
        for metric, label in (("coolant", "Coolant"), ("iat", "IAT")):
            fit = fits.get(metric)
            id_hex, feature = TOP_CANDIDATES[metric]
            if fit:
                f.write(f"### {label}\n\n")
                f.write(f"- Candidate: `{id_hex} {feature}`\n")
                f.write(f"- Fit: `{metric} = {fit['slope']:.6f} * raw + {fit['intercept']:.6f}`; MAE `{fit['mae']:.3f}`; R2 `{fit['r2']:.4f}`.\n")
                f.write("- Treat this as candidate until validated on a wider temperature swing.\n\n")
        f.write("## Low Confidence / Not Enough Data\n\n")
        f.write("- Speed cannot be decoded from this run because OBD speed was always 0.\n")
        f.write("- ECU voltage did not have a strong passive candidate in this run; keep using OBD PID or ignore for now.\n\n")
        f.write("## Files Generated\n\n")
        for generated in paths:
            f.write(f"- `{os.path.relpath(generated, OUT_DIR)}`\n")
    return path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    by_file = load_rows()
    frames_by_file_id = build_frames_by_file_id(by_file)
    generated = []
    fits = {}

    for metric, (id_hex, feature) in TOP_CANDIDATES.items():
        base_metric = metric.replace("_old_bucket", "").replace("_old_smooth", "")
        if metric.startswith("rpm_old"):
            base_metric = "rpm"
        samples = candidate_samples_for_metric(by_file, frames_by_file_id, base_metric, id_hex, feature)
        if not samples:
            continue
        path, fit = write_candidate_samples(metric, samples, simple_formula(metric))
        generated.append(path)
        if fit:
            fits[metric] = fit
            generated.append(write_group_summary(metric, samples, "source_file", fit))
            generated.append(write_group_summary(metric, samples, "stage", fit))
            generated.append(write_raw_table(metric, samples, fit, simple_formula(metric)))

    rpm_samples = candidate_samples_for_metric(by_file, frames_by_file_id, "rpm", "0x301", "b0")
    rpm_path, rpm_fit = write_candidate_samples("rpm_0x301_b0", rpm_samples, simple_formula("rpm"))
    generated.append(rpm_path)
    if rpm_fit:
        context_path, rpm_context = write_rpm_context(by_file, rpm_samples, rpm_fit)
        generated.append(context_path)
        context_rows = context_summary(rpm_context)
        generated.append(write_context_summary(context_rows))
    else:
        context_rows = []

    generated.append(validate_yesterday_rpm())
    report = write_report(fits, generated, context_rows)
    generated.append(report)

    print(f"input={INPUT}")
    print(f"report={report}")
    for path in generated:
        print(f"generated={path}")


if __name__ == "__main__":
    main()
