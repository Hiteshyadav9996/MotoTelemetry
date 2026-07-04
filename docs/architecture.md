# Architecture notes

## Target data flow

```text
Bike ECU diagnostic port
  -> 6-pin adapter
  -> ESP32 + CAN/K-Line transceiver
  -> Wi-Fi UDP packets
  -> iPhone app / laptop dashboard
```

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
