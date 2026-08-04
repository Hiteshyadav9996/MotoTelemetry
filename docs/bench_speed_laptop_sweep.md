# Bench RPM and Speedometer Sweep

Use this with the cluster on the isolated bench CAN bus and the laptop connected
to the ESP32 AP.

## Preflight

Start from a clean replay and check CAN health:

```bash
curl "http://192.168.4.1/bench/profile?mode=seqidle"
sleep 5
curl "http://192.168.4.1/bench/status"
```

Only continue if:

```text
mcp_eflg = 0x00
mcp_tec  = 0
mcp_rec  = 0
```

If the cluster shows S CAN failure or blinking, fix that before sweeping values.

## Final RPM Confirmation

This confirms `0x301 b0` from 500 rpm to 10000 rpm in 500 rpm steps:

```bash
python3 scripts/bench_rpm_sweep.py \
  --plan confirm \
  --rpm-range 500:10000:500 \
  --settle 2 \
  --recover-each
```

Type the RPM shown on the cluster after each send. Use:

- `fail` if the cluster shows S CAN failure.
- `skip` if you cannot read the value.
- `next` to move to the next candidate.
- `q` to stop.

Expected formula:

```text
display_rpm = 40 * 0x301.b0
0x301.b0 = round(rpm / 40)
```

Because this is one byte, the highest exact raw value is `0xFF`, which gives
`10200 rpm`.

## Final Speed Formula

The focused `20260727_112658` bench sweep confirmed the speedometer field:

```text
display_kph = unsigned_be16(0x30C.b0, 0x30C.b1) / 118
raw = round(kph * 118)
```

The `x118` pass covered `0..160 km/h` in `10 km/h` steps. All `17/17` prompts
were within `2 km/h`; mean absolute display error was `0.82 km/h`.

## Speedometer First Pass

Capture `d400_capture 18.csv` points strongly at wheel-speed frame `0x30C`.
In that capture, `0x30C b0,b1` as a big-endian 16-bit value was near zero in
baseline and rose to roughly `1200..1500` during `wheel_fast`.

First confirm that replaying the real wheel stream moves the speedometer:

```bash
curl "http://192.168.4.1/bench/profile?mode=seqwheel"
sleep 5
curl "http://192.168.4.1/bench/status"
```

If the speedometer moves with `seqwheel`, solve the math by sweeping only the
static `0x30C b0,b1` candidates:

```bash
python3 scripts/bench_speed_sweep.py \
  --field patch_30c_b01_be_x10 \
  --field patch_30c_b01_be_x20 \
  --field patch_30c_b01_be_x25 \
  --field patch_30c_b01_be_x40 \
  --field patch_30c_b01_be_x50 \
  --field patch_30c_b01_be_x100 \
  --speed-range 0:80:20 \
  --settle 3 \
  --recover-each
```

After the broad pass, confirm the final divisor around the fitted
`raw ~= km/h * 118` scale:

```bash
python3 scripts/bench_speed_sweep.py \
  --plan confirm30c \
  --speed-range 0:100:10 \
  --settle 3 \
  --recover-each
```

If `seqwheel` does not move the speedometer, then the cluster may require a
separate ABS/chassis wakeup that is not present in this capture.

After the focused `0x30C` pass, run the broader first pass only if needed:

```bash
python3 scripts/bench_speed_sweep.py \
  --plan fast \
  --speed-range 0:80:20 \
  --settle 2 \
  --recover-each
```

If one candidate moves the speedometer, stop with `q` and rerun only that field
with denser points:

```bash
python3 scripts/bench_speed_sweep.py \
  --field FIELD_NAME \
  --speed-range 0:160:10 \
  --settle 2 \
  --recover-each
```

If nothing moves in the fast plan, run the full low-speed pass:

```bash
python3 scripts/bench_speed_sweep.py \
  --plan full \
  --speed-range 0:80:20 \
  --settle 2 \
  --recover-each
```

List all speed fields:

```bash
python3 scripts/bench_speed_sweep.py --list-fields
```

Results are written to:

```text
analysis/final_correlation/bench_rpm_sweeps/
analysis/final_correlation/bench_speed_sweeps/
```
