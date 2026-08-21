# Dominar 400 Telemetry Starter

A starter workspace for exploring read-only telemetry from a Bajaj Dominar 400 / KTM-390-like Bosch ECU and building a custom iPhone-style display.

This updated version has a TFT-style browser dashboard inspired by the reference cluster image:

- large RPM band from 0 to 10k
- central speed readout
- gear indicator
- fuel bars
- ambient temperature
- link/status icons
- all-metrics drawer for ECU values
- raw packet viewer for debugging

Start read-only. Do not clear codes, write configurations, actuate components, or flash the ECU until the basic data path is proven and you understand the risk.

## Quick start: test the display on your laptop

```bash
cd dominar400-telemetry-starter
python3 simulator/mock_telemetry_server.py
```

Open the shown URL, usually:

```text
http://127.0.0.1:8765
```

The page streams fake telemetry at 30 Hz so you can customize the layout, gauges, sizes, and labels before connecting to the bike.

You can also open `dashboard/index.html` directly in a browser. It has a built-in demo fallback, but the Python simulator is better because it matches the live packet flow.

## Fullscreen iPhone test app

Keep the simulator running on your Mac, then open the Mac Wi-Fi URL on the iPhone, for example:

```text
http://192.168.0.4:8765
```

In Safari on iPhone, tap **Share** -> **Add to Home Screen**. Open **Dominar TFT** from the Home Screen and rotate to landscape. It launches as a fullscreen web app without Safari's address bar.

## UI files

```text
dashboard/index.html                         TFT-style laptop UI prototype
simulator/mock_telemetry_server.py           No-dependency telemetry simulator at 30 Hz
docs/ui_metric_map.md                        UI metric names and expected ECU sources
```

Important places to edit in `dashboard/index.html`:

```text
metricConfig                                 controls the all-metrics drawer
applyTelemetry(t)                            maps packet fields into the UI
demoTelemetry()                              fake data generator for UI testing
CSS variables under :root                    colors and theme
.tach-zone / .speed-wrap / .gear-box         main cluster layout
```

## Hardware path

Current hardware path (ride-minimal):

```text
Bike 6-pin diagnostic port
-> verified 6-pin-to-16-pin OBD adapter
-> OBD2 male breakout or diagnostic CANH/CANL/GND
-> ESP32-S3 TWAI + CJMCU-230 (SN65HVD230) transceiver
-> Wi-Fi SSE
-> iPhone app
```

First power the ESP32 from USB only. Use the bike connector only for CAN-H, CAN-L, and ground during discovery. Add fused 12 V to 5 V bike power only after the CAN and Wi-Fi stream are stable.

For the current ESP32-S3 + CJMCU-230 wiring and upload checklist, see `docs/esp32_s3_cjmcu230_setup.md`. The older MCP2515 SPI sketches are documented in `docs/esp32_s3_mcp2515_setup.md`.

## Data packet format

The dashboard accepts both short legacy field names and final explicit names:

```json
{
  "seq": 1,
  "ts_ms": 12345,
  "source": "can-obd",
  "rpm": 2100.0,
  "speed_kph": 37.0,
  "gear": "3",
  "fuel_pct": 70.0,
  "ambient_c": 32.0,
  "coolant_c": 82.0,
  "engine_temp_c": 85.0,
  "iat_c": 34.0,
  "map_kpa": 45.0,
  "tps_pct": 12.5,
  "battery_v": 14.1,
  "lambda": 1.0,
  "afr": 14.7,
  "ignition_deg": 16.0,
  "injector_ms": 3.2,
  "engine_load_pct": 38.0,
  "fuel_rate_lph": 2.1,
  "range_km": 240,
  "oil_temp_c": 92.0,
  "fan_on": false,
  "mil_on": false,
  "dtc_count": 0,
  "can_bitrate": 500000,
  "link_quality_pct": 100
}
```

Keep the packet small while riding. The dashboard currently accepts JSON because it is easy to debug. Once your final metric list is fixed, you can switch to a compact binary packet for lower latency.

## Files

```text
dashboard/index.html                         Laptop UI prototype
simulator/mock_telemetry_server.py           Telemetry simulator
firmware/esp32_wifi_can_bridge/              ESP32 + CAN-to-UDP bridge skeleton
ios/*.swift                                  SwiftUI app skeleton files
docs/hardware_bom.md                         Device shopping/checklist notes
docs/obd_pid_map.md                          Common PIDs and formulas
docs/architecture.md                         Data flow and implementation notes
docs/ui_metric_map.md                        Metrics used by the new UI
```
