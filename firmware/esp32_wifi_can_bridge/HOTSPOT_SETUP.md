# iPhone hotspot mode

The passive-only firmware now runs in AP+STA mode:

- Preferred: tries the primary and secondary iPhone Personal Hotspots in
  order and serves telemetry at `http://d400telemetry.local`.
- Fallback: continues hosting `D400Telemetry` at `http://192.168.4.1`.

The ESP32 uses one hotspot at a time. If it disconnects, it alternates through
the configured hotspots every 15 seconds until one becomes available.

## Configure and upload

1. Give each iPhone a unique, simple name such as `D400Phone1` and
   `D400Phone2` under
   **Settings → General → About → Name**.
2. Enable **Allow Others to Join** and **Maximize Compatibility** under
   **Settings → Personal Hotspot**.
3. Configure both credentials locally (the second hotspot is optional):

   ```bash
   cd firmware/esp32_wifi_can_bridge
   ./configure_hotspot.sh
   ```

4. Connect the ESP32-S3 over USB and upload:

   ```bash
   pio run -e d400-passive-only -t upload
   ```

5. Keep the iPhone Personal Hotspot screen open, reset the ESP32, and monitor:

   ```bash
   pio device monitor --baud 115200
   ```

Successful output includes:

```text
Hotspot connected. ESP32 IP: 172.20.10.x
App URL: http://d400telemetry.local
```

The generated `src/wifi_credentials.h` is ignored by Git.

## Test from the iPhone

1. Leave Personal Hotspot enabled and cellular data on.
2. Open Safari and load `http://d400telemetry.local/telemetry.json`.
3. Open the Flutter app and allow Local Network and Location access.
4. Confirm its status changes to `Live · http://d400telemetry.local`.
5. Swipe to Nav and confirm Google Maps loads over cellular.

If `.local` does not resolve, use the `172.20.10.x` address printed by the
serial monitor in the app's bridge settings. If hotspot connection fails, join
the fallback `D400Telemetry` Wi-Fi and use `http://192.168.4.1`.
