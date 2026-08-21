# ESP32-S3 + CJMCU-230 (TWAI) setup

This is the current ride-hardware path:

- ESP32-S3-N16R8 dev board.
- CJMCU-230 SN65HVD230 3.3 V CAN transceiver (no CAN controller on the module).
- ESP32-S3 built-in TWAI controller at 500 kbps, listen-only.
- LM2596 buck converter for later bike power.

CJMCU-230 is only a transceiver. Do not wire it like an MCP2515 SPI module. The ESP32-S3 talks to it on two GPIO pins (TWAI TX/RX), not SPI.

Start with USB power only. Do not connect the bike, LM2596, CANH, or CANL until the ESP32 firmware uploads and serial shows `TWAI started`.

## ESP32 to CJMCU-230 wiring

Power the module from ESP32 `3V3`, not `5V`. SN65HVD230 is a 3.3 V part.

```text
CJMCU-230 3V3   -> ESP32 3V3
CJMCU-230 GND   -> ESP32 GND
CJMCU-230 CTX   -> ESP32 GPIO4   (TWAI TX)
CJMCU-230 CRX   -> ESP32 GPIO5   (TWAI RX)
CJMCU-230 S/Rs  -> ESP32 GND     (high-speed mode; do not leave floating)
```

GPIO4 and GPIO5 are free on the ESP32-S3-N16R8 DevKitC-1 (not USB, not strapping, not octal flash/PSRAM).

If you get zero CAN frames after the bike is connected, swap CTX and CRX. That is the usual wiring mistake.

Leave S/Rs tied to GND. Ride firmware already uses TWAI listen-only, so the ESP32 does not ACK on the bus. Do not put the transceiver in silent/standby unless you want a hardware TX lockout.

## Bike CAN wiring later

Only after the USB bring-up works:

```text
CJMCU-230 CANH -> bike diagnostic CANH
CJMCU-230 CANL -> bike diagnostic CANL
CJMCU-230 GND  -> bike diagnostic GND
```

If the board has a 120 ohm termination jumper, remove it before connecting to the bike. The motorcycle CAN bus should already be terminated. A short stub with a fixed 120 ohm resistor often still works; if the bus looks sick, lift that resistor.

Do not connect bike 12 V directly to the ESP32. Set the LM2596 to 5.0 V first, then use:

```text
LM2596 OUT+ -> ESP32 5V/VIN
LM2596 OUT- -> ESP32 GND
```

## Firmware

The production ride firmware is:

```text
firmware/esp32_wifi_can_bridge
environment: d400-ride-minimal
```

It starts a Wi-Fi access point:

```text
SSID: D400Telemetry
Password: dominar400
Dashboard transport: binary SSE at http://192.168.4.1/events
Health: http://192.168.4.1/health.json
```

This build is listen-only. It never transmits CAN frames onto the bike bus. Passive decode still uses IDs `0x301`, `0x302`, `0x303`, `0x30C`, and `0x447`.

Legacy MCP2515 SPI sketches (`main.cpp`, `main_passive_only.cpp`, `main_obd_pid_only.cpp`) are unchanged. See `docs/esp32_s3_mcp2515_setup.md` for that wiring.

## Upload with PlatformIO

```bash
cd firmware/esp32_wifi_can_bridge
pio run -e d400-ride-minimal -t upload
pio device monitor
```

If upload does not start, put the ESP32-S3 in bootloader mode:

```text
Hold BOOT
Tap RST
Release BOOT
Upload again
```

Expected serial output starts like:

```text
D400 ride-minimal binary boot
TWAI started: 500000 bit/s, TX=GPIO4 RX=GPIO5, mode=listen-only, ok=1
```

If `ok=0`, the TWAI driver failed to install. Check GPIO4/GPIO5 are not shorted and that the board is an ESP32-S3.

If TWAI starts but `rx_frames` stays at `0` on the bike:

1. Confirm CTX is GPIO4 and CRX is GPIO5; swap them if needed.
2. Confirm S/Rs is grounded.
3. Confirm CANH/CANL/GND to the diagnostic port.
4. Confirm 500 kbps (Dominar 400 bus).

## Bench check before the bike

1. USB only, flash `d400-ride-minimal`, confirm serial `TWAI started`.
2. Optional: a USB-CAN adapter at 500 kbps. `/health.json` `rx_frames` should climb.
3. Then bike CANH/CANL/GND. RPM, speed, and gear should decode as before.
