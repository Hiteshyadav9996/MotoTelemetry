# Passive Hex Decode Map

This page separates confirmed/high-confidence Dominar 400 passive CAN values
from cluster-display values and exact OBD-equivalent signals that still need
more reverse engineering.

## Confirmed / Use First

| Signal | CAN ID | Bytes | Decode |
|---|---:|---|---|
| TPS raw | `0x301` | `b2` | `0..255`, closed grip to full grip |
| TPS grip % | `0x301` | `b2` | `raw * 100 / 255` |
| TPS OBD-equivalent % | `0x301` | `b2` | `10.588235 + raw * 0.350634` |
| Gear | `0x447` | `b5` | `0=N`, `1..6=gear` |
| Speed km/h | `0x30C` | `b0,b1` | `unsigned_be16(b0,b1) / 118` |

Gear is the strongest passive signal in the marked gear capture. `0x447 b5`
matched every gear marker exactly.

## High-Confidence / Bench Validate

| Signal | CAN ID | Bytes | Decode |
|---|---:|---|---|
| Coolant C | `0x302` | `b0,b1` | `0.099314 * signed_be16(b0,b1) + 2983.421676` |
| IAT C | `0x302` | `b5` | `0.095760 * b5 + 34.038803` |
| MAP kPa | `0x302` | `b6` | `b6 + 1` |

These match OBD truth closely in the correlation CSV. Treat them as
high-confidence for firmware decoding, then validate on the removed
odometer/cluster before relying on what the cluster displays.

## Cluster-Confirmed RPM

| Signal | CAN ID | Bytes | Decode |
|---|---:|---|---|
| Cluster/display RPM | `0x301` with fresh `0x302` | `0x301 b0` | `display_rpm = b0 * 40` |
| RPM companion / accept bytes | `0x302` | `b1,b3,b7` | Must be fresh for the cluster to accept the changed `0x301 b0` value. |

Bench isolation confirmed this path:

```text
0x301+0x302 -> 4500
0x302 -> 1500
0x301+0x302+0x303 -> 4500
0x301+0x302+0x304 -> 4500

b301=all,b302=all -> 4500
b301=all,b302=1,3,7 -> 4500
b301=0,b302=1,3,7 -> 4500
```

Treat this as the odometer/cluster tach value. It is too coarse to match exact
OBD PID `0x0C` RPM within 10 rpm on every captured sample.

Exact-RPM analysis is in
`analysis/final_correlation/exact_rpm_deep_search/deep_rpm_search_report.md`.
After de-duplication, the useful `0x301+0x302` lookup keys are almost all
single-use, so a perfect lookup on this CSV is not a reusable formula.

## Exact Active OBD RPM

| Signal | CAN ID | Bytes | Decode |
|---|---:|---|---|
| ECU RPM via OBD PID `0x0C` | `0x7E8` response | `b3,b4` when payload starts `41 0C` | `rpm = ((b3 << 8) | b4) / 4` |

The broad search uses `0x7E8` only as a sanity check. It decodes to exact OBD
RPM with zero error in this CSV, but it is the active OBD response frame, not a
normal passive broadcast frame.

## Cluster-Confirmed Speed

| Signal | CAN ID | Bytes | Decode |
|---|---:|---|---|
| Cluster/display speed km/h | `0x30C` | `b0,b1` | `display_kph = unsigned_be16(b0,b1) / 118` |

Bench sweep `bench_speed_sweep_20260727_112658.csv` confirmed the focused
`0x30C b0,b1` big-endian `x118` hypothesis from `0` to `160 km/h` in
`10 km/h` steps. All `17/17` points were within `2 km/h`; mean absolute
display error was `0.82 km/h`. Treat the small residual as display/needle
rounding rather than a different CAN formula.

## Candidate / Keep Separate

| Signal | Candidate | Status |
|---|---|---|
| RPM exact ECU/OBD PID value | not found in current passive capture | Deep search found no direct bitfield or practical affine formula under 10 rpm; use OBD PID `0x0C` for exact RPM unless a new repeated-state capture proves a passive formula. |
| RPM legacy fallback bucket | `0x310 b4`, duplicated in `b5` | Coarse bucket only: `raw * 100`; keep as fallback/off-state clue. |
| Battery/ECU voltage | `0x303 b1` | Candidate only: `battery_v = b1 / 10`. Correlation with OBD PID `0x42` had MAE about `0.06 V`, but only across a narrow `13.4..13.9 V` range. Validate with a multimeter before treating it as confirmed. |

## Bench Payload Templates

For the odometer bench test, start by sending captured full payloads exactly.
Some tail bytes may be counters or checksums, so do not assume changing only one
byte will always be accepted by the cluster.

### Gear Frames

| Gear | CAN ID | Payload |
|---|---:|---|
| N | `0x447` | `00 02 9C 4C 00 00 54 84` |
| 1 | `0x447` | `00 02 9C 63 00 01 54 84` |
| 2 | `0x447` | `00 02 9C 82 00 02 54 88` |
| 3 | `0x447` | `00 02 9C A0 00 03 54 88` |
| 4 | `0x447` | `00 02 9C BE 00 04 54 8C` |
| 5 | `0x447` | `00 02 9C DA 00 05 54 8C` |
| 6 | `0x447` | `00 02 9C F5 00 06 54 90` |

### TPS Frames

| State | CAN ID | Payload |
|---|---:|---|
| Closed | `0x301` | `00 00 00 85 00 00 00 B6` |
| About half | `0x301` | `00 00 B8 85 00 00 00 B6` |
| Full | `0x301` | `00 00 FF 85 00 00 00 B6` |

### Temperature / IAT / MAP Frames

| State | CAN ID | Payload |
|---|---:|---|
| Engine-off/cold-ish example | `0x302` | `8B A5 00 00 8B CA 5B 32` |
| Idle warming example | `0x302` | `8D AB 01 5D 8C 21 31 D1` |
| RPM idle example | `0x302` | `8B DD 01 AB 8B ED 36 A5` |

## Bench Sender Endpoint

Flash the isolated sender build:

```sh
cd "/Users/hiteshyadav/Downloads/dominar400-telemetry-starter 2/firmware/esp32_wifi_can_bridge"
pio run -e d400-bench-sender -t upload
```

Then connect to `D400Telemetry` and send a full payload:

```text
http://192.168.4.1/bench/send?id=0x447&data=00%2002%209C%2063%2000%2001%2054%2084&repeat=20&gap_ms=20
```

For odometer/cluster bench testing, prefer the continuous captured profile
sender. Single frames can leave the cluster blinking because the ECU heartbeat
is missing:

```text
http://192.168.4.1/bench/zero
http://192.168.4.1/bench/profile?mode=idle
http://192.168.4.1/bench/profile?mode=rpm2000
http://192.168.4.1/bench/profile?mode=rpm3000
http://192.168.4.1/bench/profile?mode=rpm4000
http://192.168.4.1/bench/profile?mode=seqidle
http://192.168.4.1/bench/profile?mode=seqwheel
http://192.168.4.1/bench/stop
```

The bench build autostarts the `run0` zero-RPM replay after boot. Check
`/bench/status` for `can_bitrate`, `sent_frames`, `mcp_tec`, and `mcp_rec`.
If `mcp_rec` climbs while the cluster shows `S CAN communication failure`, test
the `d400-bench-sender-250k` build before changing payload bytes.

If all static profiles still blink, use `seqidle`. It replays a 3 second real
idle sequence from `d400_correlation_combined.csv` instead of frozen example
payloads, so counter/checksum-like bytes keep moving.

For speedometer bring-up, use `seqwheel`. It replays the first 3 seconds of the
`wheel_fast` stage from `/Users/hiteshyadav/Downloads/d400_capture 18.csv`,
including the real `0x30C` wheel-speed frames.

For controlled cluster RPM testing, use the good `seqidle` background and sweep
only `0x301 b0`, while keeping the required `0x302 b1,b3,b7` companion bytes
from the selected profile:

```text
http://192.168.4.1/bench/rpm301?raw=38&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=50&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=63&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=75&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=88&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=100&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=113&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=125&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=150&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=175&profile=rpm4000
http://192.168.4.1/bench/rpm301?raw=200&profile=rpm4000
```

Expected cluster tach hint is `raw * 40 rpm`. The meter may display the nearest
rounded value.

The older `0x310` override endpoint is still available only to re-check the
legacy bucket hypothesis:

```text
http://192.168.4.1/bench/rpm310?rpm=2500&field=b45
http://192.168.4.1/bench/rpm310?raw=25&field=b45
http://192.168.4.1/bench/override?id=0x310&profile=rpm2000
http://192.168.4.1/bench/override?id=0x310&profile=rpm3000
http://192.168.4.1/bench/override?id=0x310&profile=rpm4000
```

For sanity checks, mix groups into the good `seqidle` stream:

```text
http://192.168.4.1/bench/mix?profile=rpm4000&group=all
http://192.168.4.1/bench/mix?profile=rpm4000&group=fast
http://192.168.4.1/bench/mix?profile=rpm4000&group=ecu
http://192.168.4.1/bench/mix?profile=rpm4000&group=chassis
http://192.168.4.1/bench/mix?profile=rpm4000&group=slow
```

Custom ID mixes are accepted with `ids=0x301,0x310,0x311`.
Byte masks are accepted with `/bench/mixbytes`, for example:

```text
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=all&b302=all
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=all&b302=1,3,7
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=0&b302=1,3,7
```

Parameters:

- `id`: standard 11-bit CAN ID, written as hex; both `447` and `0x447` mean `0x447`
- `data`: 1 to 8 bytes, with or without spaces
- `repeat`: optional, capped at `200`
- `gap_ms`: optional delay between repeats, capped at `250`

Use this only with the odometer/cluster isolated from the motorcycle harness.
