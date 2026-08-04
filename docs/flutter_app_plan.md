# Flutter app plan

This document captures the step-by-step plan for moving the Dominar TFT UI from the ESP32-hosted web page to a Flutter iPhone app with Google Maps.

## Current system (reference)

| Layer | File | Role |
|---|---|---|
| Firmware | `firmware/esp32_wifi_can_bridge/src/main_passive_only.cpp` | CAN decode, odometer/trip, HTTP server |
| Web UI | `firmware/esp32_wifi_can_bridge/data/index.html` | Landscape dashboard, SSE client |
| Protocol | `GET /events` | Server-Sent Events, ~50 ms telemetry JSON |
| Wi-Fi AP | `D400Telemetry` / `dominar400` | iPhone connects directly to ESP32 |

The Flutter app is a **client-only** change. No firmware modifications are required.

## Implementation phases

### Phase 1 — Flutter scaffold ✅
- Create `mobile/dominar_telemetry/` Flutter project
- Lock landscape orientation
- Add dependencies: `provider`, `http`, `google_maps_flutter`, `geolocator`, `shared_preferences`

### Phase 2 — Telemetry layer ✅
- `Telemetry` model matching `buildTelemetryPacket()` JSON fields
- `TelemetryService` SSE client for `/events` with auto-reconnect
- Demo fallback when bridge offline (same sweep animation as web UI)
- Configurable bridge URL (default `http://192.168.4.1`)

### Phase 3 — Full dashboard ✅
- Port `index.html` layout: RPM arc, speed, gear, throttle, aux, trip card
- Same colors (`#050608` background, RPM gradient, gear ring)
- Trip swipe + long-press reset via `/trip/reset`

### Phase 4 — Compact + Maps split view ✅
- Left 50%: vertical RPM bar, speed, gear ring, trip/odo swipe
- Right 50%: `GoogleMaps` with GPS position
- Matches reference mockup structure (not pixel-copy of Google UI chrome)

### Phase 5 — Navigation between views ✅
- Horizontal `PageView`: swipe whole screen Full ↔ Nav
- Page indicator dots at bottom

### Phase 6 — Device setup (manual)
- Run `flutter create .` to generate iOS/Android platform folders
- Add Google Maps API key to `AppDelegate.swift`
- Add location + local network permissions to `Info.plist`
- Build and sideload to iPhone XR

## Future enhancements (not in scope yet)

- Turn-by-turn navigation (Google Directions API)
- UDP telemetry fallback (port 4210, currently disabled in passive-only firmware)
- CarPlay / external display mirroring
- TFT hardware rendering via same Flutter engine (embedded Linux)

## File map

```
mobile/dominar_telemetry/
  lib/
    main.dart
    models/telemetry.dart
    services/telemetry_service.dart
    theme/dashboard_theme.dart
    widgets/full/          # Full dashboard components
    widgets/compact/       # Split-view left half
    screens/home_screen.dart
```
