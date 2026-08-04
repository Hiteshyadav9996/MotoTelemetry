# Bench RPM Laptop Sweep

Use this when the odometer/cluster is isolated on the bench and the ESP32 is
flashed with `d400-bench-sender`.

## Setup

1. Power the cluster from the 12 V bench battery.
2. Power the ESP32 from USB-C.
3. Keep CAN-H/CAN-L terminated at 120 ohm and use 500 kbps.
4. Connect the laptop Wi-Fi to `D400Telemetry`.
5. Confirm the ESP32 is reachable:

```sh
curl "http://192.168.4.1/bench/status"
```

The status should show `can_bitrate: 500000`, `mcp_eflg: 0x00`,
`mcp_tec: 0`, and `mcp_rec: 0` or stable.

## If S CAN Failure Appears

First restore the known-good background stream:

```sh
curl "http://192.168.4.1/bench/profile?mode=seqidle"
sleep 5
curl "http://192.168.4.1/bench/status"
```

Read the status:

- If `mcp_eflg`, `mcp_tec`, or `mcp_rec` are climbing, stop testing payloads and
  fix the bench bus first: 500 kbps build, common ground, CAN-H/CAN-L polarity,
  and 120 ohm termination.
- If the MCP counters stay clean but the cluster still says S CAN failure, the
  payload stream is being rejected. Restart clean `seqidle` and use the safer
  sweep mode below.

## Laptop Script

From the repository root:

```sh
python3 scripts/bench_rpm_sweep.py --plan known
```

This sends the confirmed `0x301 b0` tach path for:

```text
2000, 2500, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 13000
```

For each point, type the RPM shown on the cluster. The script writes a CSV under:

```text
analysis/final_correlation/bench_rpm_sweeps/
```

Useful modes:

```sh
python3 scripts/bench_rpm_sweep.py --plan fast
python3 scripts/bench_rpm_sweep.py --plan fast --recover-each
python3 scripts/bench_rpm_sweep.py --plan full
python3 scripts/bench_rpm_sweep.py --list-fields
```

Use `fast` first. Use `full` only when you have time; it is intentionally a lot
of prompts.

Use `--recover-each` while testing unknown fields. It restores clean `seqidle`
after every reading, so a bad candidate does not leave the cluster stuck in S
CAN failure.

Run one field only:

```sh
python3 scripts/bench_rpm_sweep.py --field patch_310_b45_x100
python3 scripts/bench_rpm_sweep.py --field patch_312_b23_be_x8
python3 scripts/bench_rpm_sweep.py --field patch_542_b45_be_x2
```

Run custom RPM points:

```sh
python3 scripts/bench_rpm_sweep.py --plan fast --rpms 2000,3000,5000,8000,13000
```

While running:

- Type a number like `4500` for the observed cluster RPM.
- Type `fail` if the cluster shows S CAN communication failure; the script
  records that and restores clean `seqidle`.
- Type `skip` to skip a point.
- Type `next` to skip the rest of the current field.
- Type `q` to stop.

## Candidate Fields

The `fast` plan tests these first:

| Field | Meaning |
|---|---|
| `known_301_b0_x40` | Confirmed cluster path using `/bench/rpm301`. |
| `patch_301_b0_x40` | Same byte through the generic patch endpoint. |
| `patch_310_b45_x100` | Old `0x310 b4,b5` duplicated candidate. |
| `patch_310_b2_x100` | Old `0x310 b2` candidate. |
| `patch_312_b23_be_x8` | Old smooth `0x312 b2,b3 / 8` candidate. |
| `patch_313_b23_be_x8` | Old smooth `0x313 b2,b3 / 8` candidate. |
| `patch_311_b01_be_x2` | `0x311 b0,b1` big-endian candidate. |
| `patch_311_b23_be_x2` | `0x311 b2,b3` big-endian candidate. |
| `patch_540_b3_x100` | Fast-group `0x540 b3` candidate. |
| `patch_542_b45_be_x2` | Fast-group `0x542 b4,b5` candidate. |

The `full` plan adds extra scales and endian-style candidates.

## Manual Endpoints

The new generic endpoint is:

```text
/bench/patch?id=CAN_ID&bytes=BYTE_LIST&values=HEX_BYTES&profile=rpm4000&b302=1,3,7
```

Examples:

```text
http://192.168.4.1/bench/rpm301?raw=50&profile=rpm4000&b302=1,3,7
http://192.168.4.1/bench/patch?id=0x310&bytes=4,5&values=8282&profile=rpm4000&b302=1,3,7
http://192.168.4.1/bench/patch?id=0x312&bytes=2,3&values=FA00&profile=rpm4000&b302=1,3,7
```

Meaning:

- `raw=50` on `/bench/rpm301` means `50 * 40 = 2000 rpm`.
- `values=8282` patches bytes `4,5` with `0x82,0x82`, so `0x310 b4,b5`
  tests `130 * 100 = 13000 rpm`.
- `values=FA00` patches bytes `2,3` with big-endian `0xFA00`, so
  `0x312 b2,b3 / 8` tests `64000 / 8 = 8000 rpm`.

## How To Decide Which ID Moves RPM

The script creates a summary CSV next to the raw observations. A likely tach
field will have:

- observed RPM changing as target RPM changes,
- many points within the tolerance,
- a large observed span close to the target span.

If only `known_301_b0_x40` moves the meter cleanly, then the confirmed cluster
path is still the only real tach input. If another field also tracks the target
RPM across the full sweep, send me the generated CSV and we can add it to the
decoder map.
