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
- ISO 11898-2 high-speed CAN transceiver/controller module. The current bench setup uses an MCP2515 + TJA1050 SPI CAN module.
- Optional: CANable/CANtact/USB-CAN adapter for laptop sniffing.
- Optional: small oscilloscope or logic analyzer.

## If the bike uses K-Line instead of CAN

- L9637D, MC33660, or other ISO 9141/K-Line transceiver hardware.
- KWP2000/ISO 14230-capable software or an STN/ELM-class OBD interpreter.
- Expect lower update rates than CAN.

## iPhone XR connection options

1. **Wi-Fi from ESP32/Raspberry Pi to iPhone**: easiest and fast enough for a dashboard.
2. **BLE**: clean for iOS, but usually lower throughput and more tuning work.
3. **Wired Ethernet**: possible with Lightning-to-USB 3 Camera Adapter plus USB Ethernet or an MFi Lightning-to-Ethernet adapter; physically clunky but stable.
4. **Direct custom Lightning serial**: not recommended for a hobby prototype because Apple MFi requirements apply.
