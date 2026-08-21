# ESP32-S3 USB NCM (wired iPhone telemetry)

USB Ethernet gadget for the iPhone XR through a Lightning camera adapter. The
Flutter app still uses `GET /events` binary SSE. Only the IP path changes:
`192.168.5.1` on USB instead of Wi-Fi SoftAP `192.168.4.1`.

Lightning iPhones often **fail to enumerate** ESP32 NCM. Treat the bench flash
as a go/no-go before relying on this on the bike.

## Hardware

- ESP32-S3-N16R8 DevKitC-1 (native USB-C on GPIO19/20)
- USB-A to USB-C cable
- Lightning USB camera adapter (USB 3 adapter with extra Lightning charge port preferred)
- iPhone XR, unlocked, tap **Trust** if asked
- Optional: Lightning charger in the adapter’s pass-through port so the ESP32
  does not brown out

Do not expect a USB serial port in the Flutter app. iOS will not open generic
CDC serial without MFi. The ESP32 must look like **USB Ethernet (CDC-NCM)**.

## Go / no-go bench

## Compile (no ESP32 required)

ESP-IDF will not build if the project path contains a space. This repo folder
is named `dominar400-telemetry-starter Cursor`, so compile from a copy:

```sh
cd firmware/esp32_wifi_can_bridge
./build_ncm.sh d400-ncm-bench
```

That copies the firmware to `/tmp/d400-fw` and produces
`/tmp/d400-fw/.pio/build/d400-ncm-bench/firmware.bin`. Ride firmware:

```sh
./build_ncm.sh d400-ride-usb-ncm
```

Wi-Fi `d400-ride-minimal` still builds in this folder with `pio run` — Arduino
2 does not care about the space.

## Flash (ESP32 required)

Plug the board into the **computer** (not the iPhone) while it still enumerates
as USB CDC (current Wi-Fi firmware):

```sh
cd /tmp/d400-fw
pio run -e d400-ncm-bench -t upload
```

After this firmware is on the chip, USB CDC is gone. Later flashes:

1. Hold **BOOT**
2. Plug USB-C into the computer (or camera adapter attached to a computer)
3. Tap **RST**, release **BOOT**
4. `cd /tmp/d400-fw && pio run -e d400-ncm-bench -t upload`

Plug ESP32 → camera adapter → iPhone XR.

**Pass**

- iPhone **Settings → Ethernet** appears
- DHCP address in `192.168.5.2`–`192.168.5.10`
- Safari: `http://192.168.5.1/health.json` returns `"transport":"usb-ncm"`

**Fail** (Ethernet never appears, or no IP after several replugs)

Stop NCM. Pivot to the proven Lightning path:

- Lightning camera adapter
- USB Ethernet dongle (ASIX AX88772 / RTL8153 / Apple USB Ethernet)
- W5500 (or similar) SPI Ethernet on the ESP32
- Same app URL idea: HTTP SSE on a local Ethernet subnet

Espressif’s own NCM tests worked on USB-C iPhones and often did **not**
enumerate on Lightning.

## Ride firmware (only after bench passes)

```sh
cd /tmp/d400-fw
pio run -e d400-ride-usb-ncm -t upload
```

This build:

- TinyUSB NCM at `192.168.5.1/24`
- DHCP pool `.2`–`.10` with **no default gateway and no DNS** so iOS keeps
  Wi-Fi/cellular for Google Maps
- Same binary SSE as `d400-ride-minimal`
- SoftAP **off** so the iPhone can join another phone’s hotspot

`d400-ride-minimal` is unchanged Wi-Fi firmware if you need to ride without USB.

## Ride setup

1. Power the ESP32 from the LM2596 `VIN` on the bike. Treat iPhone USB as data.
   Avoid back-feeding 5 V into Lightning. Charge the iPhone from the camera
   adapter’s Lightning pass-through if you want.
2. USB-C from ESP32 into the camera adapter.
3. Confirm **Settings → Ethernet** shows `192.168.5.x`.
4. Join the other phone’s hotspot (or use XR cellular) for maps.
5. Open the app. Status should be `Live · http://192.168.5.1`.
6. If Maps fail, Ethernet is the default route: **Settings → Ethernet →
   Configure IP → Manual**, keep IP and subnet, leave **Router** blank.

## Dual Wi-Fi + cable (not implemented)

Possible later: same HTTP server on USB `192.168.5.1` and SoftAP `192.168.4.1`.
The app already tries USB then SoftAP. Dual is a cable-unplugged fallback, not
more throughput. USB Full Speed is already far above the 20 Hz telemetry stream.

## Power and flashing notes

- `ARDUINO_USB_MODE=0` takes over the USB-C port as OTG NCM. Serial monitor on
  that cable stops. UART0 (GPIO43/44) is the debug serial if you need it.
- NCM firmware is Arduino as an ESP-IDF component (TinyUSB NCM is not in the
  prebuilt Arduino 3 libs). First compile takes several minutes.
