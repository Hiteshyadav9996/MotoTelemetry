# Architecture notes

## Target data flow

Current production ride path is Wi-Fi SoftAP + HTTP SSE. Wired USB Ethernet
(NCM) is an alternate path that keeps the same SSE packets:

```text
Bike ECU diagnostic port
  -> 6-pin adapter
  -> ESP32-S3 TWAI + CJMCU-230
  -> USB NCM (Ethernet gadget) 192.168.5.1   or   Wi-Fi SoftAP 192.168.4.1
  -> HTTP SSE GET /events (binhex, 20 Hz)
  -> iPhone Flutter app
```

USB Ethernet leaves the iPhone Wi-Fi free for another phone hotspot (maps).
DHCP on the ESP32 must not advertise a default gateway. See
`docs/esp32_s3_usb_ncm_iphone.md`.

Legacy lab sketches also broadcast JSON UDP on port 4210. Ride-minimal does not.

## Why not a cheap ELM327 clone?

Cheap ELM327-style adapters are convenient, but they often poll one PID at a time through a slow AT-command serial layer. That is fine for maintenance, but poor for a custom realtime display. A direct CAN bridge reduces the layers:

```text
Cheap adapter path: app -> Bluetooth -> ELM AT command -> ECU request -> ECU response -> ELM text parse -> app
Custom path: ESP32 -> CAN frame -> ECU response -> compact UDP packet -> app
```

## Read-only phases

1. Identify the physical protocol: CAN, K-Line, or both.
2. Capture the ECU's response to standard PIDs.
3. Build a metric map.
4. Stream only metrics that are needed for the display.
5. Add smoothing and loss handling in the app.

## Suggested update rates

- RPM: 20 to 50 Hz if possible.
- Throttle: 20 to 50 Hz.
- Speed: 10 to 20 Hz.
- Coolant temperature: 1 to 5 Hz.
- Intake air temperature: 1 to 5 Hz.
- Battery voltage: 1 to 5 Hz.

Do not waste ECU bandwidth by polling slow-changing values at tachometer speed.
