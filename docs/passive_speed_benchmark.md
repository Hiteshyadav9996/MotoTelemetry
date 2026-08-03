# Ride-Minimal Binary Telemetry (Path C)

Production ride firmware (`d400-ride-minimal`) uses **binary SSE only**.

## Wire format

SSE frames on `GET /events`:

```text
data: binhex:44010000...\n\n
```

- Prefix: `binhex:`
- Payload: hex-encoded packed `RideTelemetryBinary` struct (78 bytes)
- Rate: 20 Hz (50 ms interval)

Gear is **precomputed on decode** (`gDisplayGear[0]`) and copied into the struct at publish time — no string allocation in the hot path.

## Endpoints (ride build)

| Path | Purpose |
|------|---------|
| `/events` | Binary SSE telemetry |
| `/health.json` | On-demand CAN/link diagnostics (JSON) |
| `/bench/status` | Timing hooks (JSON) |
| `/trip/reset?slot=N` | Reset trip meter |

No LittleFS, no static HTML, no `/telemetry.json`.

## Flash

```bash
cd firmware/esp32_wifi_can_bridge
pio run -e d400-ride-minimal -t upload
```

## Phone app

Flutter `TelemetryService` parses `binhex:` via `Telemetry.fromBinaryHex()`. JSON SSE is kept as a fallback for lab/legacy firmware only.

## Lab firmware

Use `d400-lab-debug` for capture/correlate/canlog — still JSON SSE with full debug tooling.

## Benchmark metrics

`GET /bench/status`:

```json
{
  "can_drain_us": 120,
  "pack_us": 45,
  "sse_send_us": 800,
  "loop_us_max": 3200,
  "sse_skipped_delta": 0,
  "transport": "binary"
}
```

Success targets: P95 packet age < 100 ms, skip rate < 1%, loop P99 < 5 ms.
