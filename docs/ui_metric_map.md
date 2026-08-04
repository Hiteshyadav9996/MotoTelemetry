# UI Metric Map

The browser dashboard is intentionally more complete than the first ECU prototype. It lets you design the screen now, then wire each value to a real ECU source later.

## Main TFT cluster

| UI value | Packet field | Likely source | First priority |
|---|---|---|---|
| RPM arc | `rpm` | OBD PID 01 0C or broadcast CAN | High |
| Speed | `speed_kph` or `speed` | OBD PID 01 0D, ABS/cluster CAN, or GPS fallback | High |
| Gear | `gear` | Gear sensor/CAN if available, otherwise calculate from speed and RPM | Medium |
| Odometer | `odometer_km` | Integrated from decoded speed and persisted in ESP32 NVS | Medium |
| Fuel bars | `fuel_pct` | Cluster/CAN if available, otherwise phone/app estimate | Medium |
| Ambient temp | `ambient_c` | Phone/weather sensor, cluster CAN, or manual setting | Low |
| MIL | `mil_on` | OBD monitor/MIL status or DTC scan | High |
| Fan | `fan_on` | Manufacturer-specific PID or inferred from coolant threshold | Medium |
| DTC indicator | `dtc_count` | OBD DTC query | High |
| Link bars | `link_quality_pct` | ESP32 bridge Wi-Fi quality / packet age | High |

## All-metrics drawer

| UI value | Packet field | Standard OBD possibility | Notes |
|---|---|---|---|
| RPM | `rpm` | 01 0C | Should be high-rate, 20-50 Hz if possible. |
| Speed | `speed_kph` | 01 0D | Might come from ABS/cluster instead of engine ECU. |
| Throttle | `tps_pct` | 01 11 | High-rate useful for UI. |
| Coolant | `coolant_c` | 01 05 | Slow-changing, 1-5 Hz is enough. |
| Engine temp | `engine_temp_c` | not always standard | Can mirror coolant if no separate value exists. |
| Intake air | `iat_c` | 01 0F | From TMAP sensor. |
| MAP | `map_kpa` | 01 0B | From TMAP sensor. |
| Battery | `battery_v` | 01 42 | Good for health/status display. |
| Lambda | `lambda` | O2/lambda PID varies | May need ECU-specific decoding. |
| AFR | `afr` | derived from lambda | `afr = lambda * 14.7` for gasoline. |
| Ignition | `ignition_deg` | 01 0E sometimes | Support varies. |
| Injector | `injector_ms` | usually manufacturer-specific | Useful if discoverable. |
| Load | `engine_load_pct` | 01 04 | Computed ECU load. |
| Fuel rate | `fuel_rate_lph` | derived or manufacturer-specific | Can estimate from injector pulse width later. |
| Fuel | `fuel_pct` | not usually engine OBD | Often cluster/body data. |
| Range | `range_km` | app estimate | Derived from fuel and consumption. |
| Oil temp | `oil_temp_c` | 01 5C if supported | Many motorcycles do not expose this. |
| DTC count | `dtc_count` | OBD DTC query | Query periodically, not high-rate. |

## Recommended update rates

| Group | Rate |
|---|---:|
| RPM, throttle | 20-50 Hz |
| MAP, speed | 10-25 Hz |
| coolant, intake air, battery | 1-5 Hz |
| fuel, range, DTC count | occasional |

The simulator sends everything at 30 Hz only so the UI is smooth during development. The real bridge should poll each group at its own rate.
