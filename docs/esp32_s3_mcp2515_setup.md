# ESP32-S3 + MCP2515 setup

This setup matches the hardware currently on hand:

- ESP32-S3-N16R8 dev board.
- Blue MCP2515 + TJA1050 CAN module.
- LM2596 buck converter for later bike power.

Start with USB power only. Do not connect the bike, LM2596, CANH, or CANL until the ESP32 firmware uploads and the MCP2515 is detected over SPI.

## ESP32 to MCP2515 wiring

Power the MCP2515 module from ESP32 `3V3`, not `5V`, when wiring it directly to ESP32 GPIO.

```text
MCP2515 VCC      -> ESP32 3V3
MCP2515 GND      -> ESP32 GND
MCP2515 SCK      -> ESP32 GPIO12
MCP2515 SI/MOSI  -> ESP32 GPIO11
MCP2515 SO/MISO  -> ESP32 GPIO13
MCP2515 CS       -> ESP32 GPIO10
MCP2515 INT      -> ESP32 GPIO9
```

The common TJA1050 module is normally a 5 V CAN module. Running it from 3.3 V is the safest direct-to-ESP32 test, but the CAN side may or may not work reliably on the bike. If SPI detection works but CAN never receives bike frames, the likely blocker is electrical, not the app.

## Bike CAN wiring later

Only after the bench upload works:

```text
MCP2515 CANH -> bike diagnostic CANH
MCP2515 CANL -> bike diagnostic CANL
MCP2515 GND  -> bike diagnostic GND
```

Remove the yellow 120 ohm termination jumper before connecting to the bike. The motorcycle CAN bus should already be terminated.

Do not connect bike 12 V directly to the ESP32. Set the LM2596 to 5.0 V first, then use:

```text
LM2596 OUT+ -> ESP32 5V/VIN
LM2596 OUT- -> ESP32 GND
```

## Firmware

The firmware is in:

```text
firmware/esp32_wifi_can_bridge
```

The default build is currently a Wi-Fi/mock telemetry test build. It does not use CAN or the bike yet. It starts a Wi-Fi access point:

```text
SSID: D400Telemetry
Password: dominar400
UDP telemetry: 192.168.4.255:4210
Dashboard: http://192.168.4.1
Simple test page: http://192.168.4.1/test
```

Open `http://192.168.4.1` on a phone connected to `D400Telemetry` to verify the real HTML dashboard with live ESP32 mock RPM, speed, coolant temperature, and throttle packets.

The dashboard files are uploaded through LittleFS from:

```text
firmware/esp32_wifi_can_bridge/data
```

When `dashboard/index.html` changes, refresh the ESP32 copy and upload the filesystem again:

```bash
cp ../../dashboard/index.html data/index.html
cp ../../dashboard/manifest.webmanifest data/manifest.webmanifest
cp ../../dashboard/icon.svg data/icon.svg
pio run -t uploadfs
```

When firmware changes, upload firmware:

```bash
pio run -t upload
```

To switch from Wi-Fi/mock testing to real CAN testing, change this line in `src/main.cpp`:

```cpp
static const bool WIFI_MOCK_TELEMETRY_ENABLED = true;
```

to:

```cpp
static const bool WIFI_MOCK_TELEMETRY_ENABLED = false;
```

In real CAN mode, it sends read-only OBD-II Mode 01 PID requests through the MCP2515:

- RPM
- Speed
- Throttle position
- Coolant temperature
- Intake air temperature
- Manifold pressure
- ECU voltage

## Upload with PlatformIO

Open the firmware folder in VS Code with PlatformIO installed, then run:

```bash
pio run -t upload
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
Dominar 400 ESP32-S3 MCP2515 bridge booting...
Wi-Fi AP: D400Telemetry
AP IP: 192.168.4.1
MCP2515 started: 8 MHz crystal, 500000 bit/s
```

If you see `MCP2515 not detected over SPI`, check VCC, GND, SCK, SI, SO, and CS wiring first.

If the MCP2515 is detected but `rx_responses` stays at `0` on the bike, check the silver crystal marking on the CAN board. If it says `16.000`, change `MCP_CLOCK_MHZ` in `src/main.cpp` from `8` to `16`.
