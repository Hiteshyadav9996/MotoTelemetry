# Hardware checklist

## Minimum safe exploration kit

- Bajaj/KTM 6-pin diagnostic connector to 16-pin OBD-II adapter cable.
- Multimeter.
- Known-good OBD adapter for laptop testing.
- Inline fuse holder, 0.5 A to 1 A fuse for your custom electronics supply.
- Automotive buck converter: 12 V battery/ACC input to stable 5 V output.
- Heat-shrink, waterproof enclosure, strain relief, and proper crimp terminals.

## Faster custom bridge for CAN bikes

- ESP32 DevKit or ESP32-S3 board.
- ISO 11898-2 high-speed CAN transceiver. The current ride setup uses a CJMCU-230 (SN65HVD230) 3.3 V transceiver on the ESP32-S3 built-in TWAI controller. See `docs/esp32_s3_cjmcu230_setup.md`.
- Legacy bench sketches still support an MCP2515 + TJA1050 SPI CAN module. See `docs/esp32_s3_mcp2515_setup.md`.
- Optional: CANable/CANtact/USB-CAN adapter for laptop sniffing.
- Optional: small oscilloscope or logic analyzer.

## If the bike uses K-Line instead of CAN

- L9637D, MC33660, or other ISO 9141/K-Line transceiver hardware.
- KWP2000/ISO 14230-capable software or an STN/ELM-class OBD interpreter.
- Expect lower update rates than CAN.

## iPhone XR connection options

1. **Wi-Fi from ESP32 SoftAP to iPhone**: `d400-ride-minimal`, SSID `D400Telemetry`, `http://192.168.4.1`. Easiest. The phone joins the bike AP, so maps need cellular (iOS often fails that) or you skip navigation.
2. **USB Ethernet (NCM) through Lightning camera adapter**: `d400-ncm-bench` then `d400-ride-usb-ncm`. App URL `http://192.168.5.1`. Fast and stable if iOS enumerates the gadget. Lightning iPhones often do **not**. See `docs/esp32_s3_usb_ncm_iphone.md`.
3. **Lightning camera adapter + USB Ethernet dongle (ASIX/RTL8153) + W5500 on ESP32**: extra parts, but iOS USB Ethernet adapters are proven. Use this if NCM never appears under Settings → Ethernet.
4. **BLE**: clean for iOS, lower throughput, not implemented.
5. **Direct custom Lightning serial**: not recommended. Apple MFi is required; the Flutter app cannot open generic USB CDC.
