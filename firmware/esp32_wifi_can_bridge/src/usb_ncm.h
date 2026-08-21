#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// USB NCM Ethernet gadget at 192.168.5.1. No-ops when CONFIG_TINYUSB_NET_MODE_NCM
// is unset (Wi-Fi Arduino 2 builds).

bool usb_ncm_start(void);
void usb_ncm_maintain(void);
bool usb_ncm_host_mounted(void);
uint8_t usb_ncm_station_count(void);

#ifdef __cplusplus
}
#endif
