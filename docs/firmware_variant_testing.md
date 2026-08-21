# Firmware Variant Testing

This project now has these PlatformIO environments:

- `d400-ride-minimal`: production ride firmware. ESP32-S3 **TWAI** + CJMCU-230 transceiver over **Wi-Fi SoftAP**. See `docs/esp32_s3_cjmcu230_setup.md`.
- `d400-ncm-bench`: USB Ethernet gadget go/no-go (`http://192.168.5.1/health.json`). See `docs/esp32_s3_usb_ncm_iphone.md`.
- `d400-ride-usb-ncm`: same ride telemetry as `d400-ride-minimal`, over USB NCM instead of SoftAP. Flash only after the bench enumerates on the iPhone.
- `esp32-s3-devkitc-1`: reference firmware from `src/main.cpp` (**MCP2515 SPI**)
- `d400-passive-only`: passive CAN decode test from `src/main_passive_only.cpp` (**MCP2515 SPI**)
- `d400-obd-polling`: active OBD PID polling test from `src/main_obd_pid_only.cpp` (**MCP2515 SPI**)
- `d400-bench-sender`: isolated odometer/cluster bench sender from `src/main.cpp` (**MCP2515 SPI**)

Ride-minimal is the only environment wired for CJMCU-230. The MCP2515 sketches still expect the blue SPI module.

## Ride-minimal (TWAI + CJMCU-230)

Flash:

```sh
cd firmware/esp32_wifi_can_bridge
pio run -e d400-ride-minimal -t upload
```

Serial should show `TWAI started: 500000 bit/s, TX=GPIO4 RX=GPIO5, mode=listen-only, ok=1`.

Validation:

- `/health.json` `controller` should be `twai`
- `tx` stays off; this build is listen-only
- `rx_frames` should increase on the bike
- `can_rx_overflows` should stay flat after boot
- RPM/speed/gear still decode from `0x301` / `0x30C` / `0x447`

## USB NCM bench and ride

Compile without the ESP32 plugged in. This folder name has a space, so IDF
builds must go through the helper:

```sh
cd firmware/esp32_wifi_can_bridge
./build_ncm.sh d400-ncm-bench
```

Flash with the board on the computer:

```sh
cd /tmp/d400-fw
pio run -e d400-ncm-bench -t upload
```

Pass: iPhone **Settings → Ethernet** gets `192.168.5.x` and Safari loads
`http://192.168.5.1/health.json`. Then:

```sh
cd /tmp/d400-fw
pio run -e d400-ride-usb-ncm -t upload
```

After NCM firmware, reflash with BOOT held (USB CDC is gone). Full procedure:
`docs/esp32_s3_usb_ncm_iphone.md`.

## Passive-only Build

This build never transmits CAN frames. It listens only.

Implemented passive decodes:

- TPS, confirmed: `0x301 b2`
  - grip percent: `raw * 100 / 255`
  - OBD-equivalent absolute percent: `10.588235 + raw * 0.350634`
- Gear, confirmed: `0x447 b5`, where `0=N`, `1..6=gear`
- Coolant, high-confidence: `0.099314 * signed_be16(0x302 b0,b1) + 2983.421676`
- IAT, high-confidence: `0.095760 * 0x302 b5 + 34.038803`
- MAP, high-confidence: `0x302 b6 + 1`
- Speed, bench-confirmed: `unsigned_be16(0x30C b0,b1) / 118`
- Battery voltage, candidate: `0x303 b1 / 10`

Separated candidate/unknown values:

- Cluster/display RPM, bench-confirmed: `0x301 b0 * 40`, accepted by the
  cluster when companion bytes `0x302 b1,b3,b7` are fresh.
- RPM exact ECU/OBD PID value is not finalized passively; `0x301 b0 * 40` is
  too coarse to match OBD PID `0x0C` within 10 rpm on every sample.
- Exact ECU RPM is available through active OBD response `0x7E8` with
  `rpm = ((b3 << 8) | b4) / 4` when the payload starts `41 0C`.
- Coarse legacy bucket: `0x310 b4` duplicated in `b5`, formula `raw * 100`.
  Keep this only as a fallback/off-state clue, not as the trusted tach source.
- Battery voltage is not finalized passively yet; the passive-only firmware
  exposes candidate `0x303 b1 / 10` as `battery_v` and labels
  `battery_source` as `passive-can-0x303-candidate`.

See `docs/passive_hex_decode_map.md` for the confirmed ID list, payload templates, and bench-send workflow.

Flash:

```sh
cd "/Users/hiteshyadav/Downloads/dominar400-telemetry-starter 2/firmware/esp32_wifi_can_bridge"
pio run -e d400-passive-only -t upload
```

Monitor:

```sh
pio device monitor --port /dev/cu.usbmodem1101 --baud 115200
```

Phone:

```text
Wi-Fi: D400Telemetry
URL:   http://192.168.4.1
```

Validation:

- `source` should be `passive-only`
- `tx_requests` must stay `0`
- `filter_mode` in `/canlog.json` should be `important-decoded-ids` for the
  low-lag riding build
- `rx_frames` should increase
- `mcp_rx_overflows` should stay flat after boot; if it keeps increasing, the
  MCP2515 is still dropping frames
- `rpm` should be `0` when engine is off
- `rpm` should come from `0x301 b0 * 40` once paired `0x301/0x302` frames arrive
- `decoded_rpm_id_hex` should normally be `0x301`; `0x310` means fallback only
- `tps_raw` should move from `0` to `255`
- `gear_raw` should be `0..6`
- `speed_source` should be `passive-can-0x30c` once wheel-speed frames arrive
- `speed_raw` should match `round(speed_kph * 118)` within display rounding
- `battery_source` should be `passive-can-0x303-candidate` once `0x303` arrives
- compare `battery_v` against a multimeter before trusting the passive candidate
- `coolant_raw`, `iat_raw`, and `map_raw` should appear after `0x302` frames arrive

For future full-bus reverse engineering captures, temporarily set
`MCP_FILTER_IMPORTANT_IDS_ONLY = false` in `src/main_passive_only.cpp`. The
filtered riding build intentionally ignores undecoded IDs to protect the
MCP2515 RX buffers.

## Bench Sender Build

Use this only with the odometer/cluster isolated from the motorcycle harness.
This build exposes a manual endpoint for sending exact 11-bit CAN payloads:

```sh
cd "/Users/hiteshyadav/Downloads/dominar400-telemetry-starter 2/firmware/esp32_wifi_can_bridge"
pio run -e d400-bench-sender -t upload
```

The default bench sender uses `500000` bps. If the cluster still shows
`S CAN communication failure` and `/bench/status` shows `mcp_rec` climbing,
try the 250 kbps variant:

```bash
cd "/Users/hiteshyadav/Downloads/dominar400-telemetry-starter 2/firmware/esp32_wifi_can_bridge"
pio run -e d400-bench-sender-250k -t upload
```

Example, send the captured first-gear payload twenty times:

```text
http://192.168.4.1/bench/send?id=0x447&data=00%2002%209C%2063%2000%2001%2054%2084&repeat=20&gap_ms=20
```

If the cluster blinks or reports engine kill switch, use the continuous profile
replay instead of one-off frames. It sends a captured background CAN set at
regular intervals:

```text
http://192.168.4.1/bench/zero
http://192.168.4.1/bench/profile?mode=idle
http://192.168.4.1/bench/profile?mode=rpm2000
http://192.168.4.1/bench/profile?mode=rpm3000
http://192.168.4.1/bench/profile?mode=rpm4000
http://192.168.4.1/bench/profile?mode=run0
http://192.168.4.1/bench/profile?mode=seqidle
http://192.168.4.1/bench/status
http://192.168.4.1/bench/stop
```

The `d400-bench-sender` build also autostarts the `run0` zero-RPM replay after
boot. Use `/bench/status` to check `can_bitrate`, `sent_frames`, `mcp_tec`, and
`mcp_rec`.

For laptop-driven intensive RPM sweeps, use
`docs/bench_rpm_laptop_sweep.md` and `scripts/bench_rpm_sweep.py`. The script
tests `2000` through `13000 rpm`, prompts for the cluster reading, and writes a
CSV showing which candidate ID/field actually tracks the meter.

If the static profiles still leave the cluster blinking, try `seqidle`. It
replays a 3 second real idle CAN slice from the correlation CSV, preserving the
changing payload bytes that may be alive counters or checksums.

For controlled cluster RPM testing, keep the `seqidle` background and mix known
RPM payloads into it. This keeps the heartbeat/counter-like traffic alive while
you isolate the payloads that actually move the meter:

```text
http://192.168.4.1/bench/mix?profile=rpm4000&group=all
http://192.168.4.1/bench/mix?profile=rpm4000&group=fast
http://192.168.4.1/bench/mix?profile=rpm4000&group=ecu
http://192.168.4.1/bench/mix?profile=rpm4000&group=chassis
http://192.168.4.1/bench/mix?profile=rpm4000&group=slow
```

Custom mixes are also supported:

```text
http://192.168.4.1/bench/mix?profile=rpm4000&ids=0x301,0x302
http://192.168.4.1/bench/mix?profile=rpm4000&ids=0x301,0x302,0x303
http://192.168.4.1/bench/mix?profile=rpm4000&ids=0x301,0x302,0x304
```

Use byte-mask mixes to isolate the exact payload bytes while still keeping the
real `seqidle` background. Argument names are `b` plus the hex CAN ID without
`0x`; values can be `all`, a list such as `1,3,7`, a range such as `0-3`, or a
hex mask such as `0x89`.

```text
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=all&b302=all
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=all&b302=1,3,7
http://192.168.4.1/bench/mixbytes?profile=rpm4000&b301=0&b302=1,3,7
http://192.168.4.1/bench/mixbytes?profile=rpm4000&id=0x302&bytes=1,3,7
```

Current bench isolation:

```text
0x301+0x302 -> 4500
0x302 -> 1500
0x301+0x302+0x303 -> 4500
0x301+0x302+0x304 -> 4500

b301=all,b302=all -> 4500
b301=all,b302=1,3,7 -> 4500
b301=0,b302=1,3,7 -> 4500
```

This makes `0x301 b0` the cluster tach byte, with `0x302 b1,b3,b7`
required as a companion set for the cluster to accept the changed tach value.
Use `/bench/rpm301` to sweep only `0x301 b0` while keeping the accepted
`0x302` companion bytes from a static profile:

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

Expected cluster tach hint is `raw * 40 rpm`, usually rounded by the meter.

The older `0x310` endpoints are still present for fallback checks only:

```text
http://192.168.4.1/bench/rpm310?rpm=2500&field=b45
http://192.168.4.1/bench/override?id=0x310&profile=rpm4000
```

The endpoint is disabled in the normal and passive-only builds.

## OBD-polling Build

This build enters normal CAN mode and sends standard OBD Mode 01 PID requests.
Passive decodes are deliberately ignored.

Polling targets:

- RPM: 5 Hz, PID `0x0C`
- TPS: 5 Hz, PID `0x11`
- MAP: 2 Hz, PID `0x0B`
- Speed: 2 Hz, PID `0x0D`
- Coolant: 1 Hz, PID `0x05`
- IAT: 0.5 Hz, PID `0x0F`
- ECU voltage: 0.5 Hz, PID `0x42`

The scheduler sends one PID request at a time. Standard OBD cannot truly fetch
all these values in one single request/response; the dashboard is built from the
latest successful value for each PID.

For exact RPM, the ECU response frame is `0x7E8`; payload bytes `41 0C A B`
decode as `((A << 8) | B) / 4` rpm. The passive broadcast search did not find a
separate reusable under-10-rpm formula in the current capture.

Flash:

```sh
cd "/Users/hiteshyadav/Downloads/dominar400-telemetry-starter 2/firmware/esp32_wifi_can_bridge"
pio run -e d400-obd-polling -t upload
```

Monitor:

```sh
pio device monitor --port /dev/cu.usbmodem1101 --baud 115200
```

Phone:

```text
Wi-Fi: D400Telemetry
URL:   http://192.168.4.1
```

Validation:

- `source` should be `obd-polling`
- `tx_requests` should increase
- `rx_responses` should increase
- `pid_timeouts` should stay low relative to `tx_requests`
- If `pid_timeouts` rises quickly or values lag badly, even the reduced 16 requests/sec target is too aggressive for this ECU/module path

## What The Existing Data Proves

The previous correlation captures used a conservative OBD schedule and reached
about `7.2` OBD requests/sec with `~75-81%` success depending on PID. That proves
standard PIDs work, but it does not prove the reduced `16 requests/sec` schedule
will be stable. The `d400-obd-polling` environment is intentionally the live test
for that.

If OBD-polling is still laggy, reduce the targets in `src/main_obd_pid_only.cpp`:

- RPM/TPS from `200 ms` to `300 ms`
- MAP/speed from `500 ms` to `1000 ms`
- Keep coolant at `1000 ms`
- Keep IAT/battery at `2000 ms`
