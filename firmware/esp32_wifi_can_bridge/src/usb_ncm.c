#include "usb_ncm.h"

#include "sdkconfig.h"

#ifndef CONFIG_TINYUSB_NET_MODE_NCM

bool usb_ncm_start(void) { return false; }
void usb_ncm_maintain(void) {}
bool usb_ncm_host_mounted(void) { return false; }
uint8_t usb_ncm_station_count(void) { return 0; }

#else

#include <stdlib.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "tinyusb.h"
#include "tinyusb_net.h"
#include "tusb.h"

#if __has_include("dhcpserver/dhcpserver.h")
#include "dhcpserver/dhcpserver.h"
#endif

#ifndef OFFER_START
#define OFFER_START 0x00
#endif

static const char *TAG = "usb_ncm";

#define D400_USB_IP_A 192
#define D400_USB_IP_B 168
#define D400_USB_IP_C 5
#define D400_USB_IP_D 1
#define D400_USB_DHCP_POOL_START 2
#define D400_USB_DHCP_POOL_END 10

typedef struct {
  esp_netif_driver_base_t base;
  uint8_t netif_mac[6];
  uint8_t usb_mac[6];
} usb_ncm_driver_t;

static usb_ncm_driver_t s_driver;
static volatile bool s_link_up;
static volatile bool s_mounted;
static volatile bool s_started;

static void make_local_mac(uint8_t out[6], const uint8_t base[6], uint8_t offset) {
  memcpy(out, base, 6);
  uint16_t low = (uint16_t)out[5] + offset;
  out[5] = (uint8_t)(low & 0xFF);
  out[4] = (uint8_t)(out[4] + (low >> 8));
  out[0] |= 0x02;
  out[0] &= (uint8_t)~0x01;
}

static void set_link_state(bool up) {
#if CFG_TUD_NCM
  tud_network_link_state(0, up);
#endif
  s_link_up = up;
  ESP_LOGI(TAG, "NCM link %s", up ? "up" : "down");
}

static esp_err_t usb_ncm_transmit(void *h, void *buffer, size_t len) {
  (void)h;
  if (buffer == NULL || len == 0) {
    return ESP_OK;
  }
  if (len > UINT16_MAX) {
    return ESP_ERR_INVALID_ARG;
  }
  return tinyusb_net_send_sync(buffer, (uint16_t)len, NULL, pdMS_TO_TICKS(80));
}

static void usb_ncm_free_rx(void *h, void *buffer) {
  (void)h;
  free(buffer);
}

static esp_err_t usb_ncm_recv_cb(void *buffer, uint16_t len, void *ctx) {
  usb_ncm_driver_t *driver = (usb_ncm_driver_t *)ctx;
  if (driver == NULL || driver->base.netif == NULL || buffer == NULL || len == 0) {
    return ESP_OK;
  }
  void *copy = malloc(len);
  if (copy == NULL) {
    return ESP_ERR_NO_MEM;
  }
  memcpy(copy, buffer, len);
  return esp_netif_receive(driver->base.netif, copy, len, copy);
}

static esp_err_t usb_ncm_post_attach(esp_netif_t *esp_netif, void *args) {
  usb_ncm_driver_t *driver = (usb_ncm_driver_t *)args;
  driver->base.netif = esp_netif;
  const esp_netif_driver_ifconfig_t ifconfig = {
      .handle = driver,
      .transmit = usb_ncm_transmit,
      .driver_free_rx_buffer = usb_ncm_free_rx,
  };
  ESP_ERROR_CHECK(esp_netif_set_driver_config(esp_netif, &ifconfig));
  ESP_ERROR_CHECK(esp_netif_set_mac(esp_netif, driver->netif_mac));
  return ESP_OK;
}

static esp_err_t configure_dhcp(esp_netif_t *netif) {
  uint32_t lease_time = 120;
  esp_err_t err = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, ESP_NETIF_IP_ADDRESS_LEASE_TIME,
                                         &lease_time, sizeof(lease_time));
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "lease time option failed: %s", esp_err_to_name(err));
  }

  dhcps_lease_t pool = {
      .enable = true,
  };
  pool.start_ip.addr = ESP_IP4TOADDR(D400_USB_IP_A, D400_USB_IP_B, D400_USB_IP_C,
                                     D400_USB_DHCP_POOL_START);
  pool.end_ip.addr = ESP_IP4TOADDR(D400_USB_IP_A, D400_USB_IP_B, D400_USB_IP_C,
                                   D400_USB_DHCP_POOL_END);
  err = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, ESP_NETIF_REQUESTED_IP_ADDRESS, &pool,
                               sizeof(pool));
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "DHCP pool option failed: %s", esp_err_to_name(err));
  }

  // No default gateway or DNS: iOS keeps Wi-Fi/cellular as the internet route.
  dhcps_offer_t offer_off = OFFER_START;
  err = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, ESP_NETIF_ROUTER_SOLICITATION_ADDRESS,
                               &offer_off, sizeof(offer_off));
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "disable DHCP router failed: %s", esp_err_to_name(err));
  }
  err = esp_netif_dhcps_option(netif, ESP_NETIF_OP_SET, ESP_NETIF_DOMAIN_NAME_SERVER, &offer_off,
                               sizeof(offer_off));
  if (err != ESP_OK) {
    ESP_LOGW(TAG, "disable DHCP DNS failed: %s", esp_err_to_name(err));
  }
  return ESP_OK;
}

static void usb_ncm_on_init(void *ctx) {
  (void)ctx;
  s_mounted = true;
  ESP_LOGI(TAG, "USB NCM class initialized by host");
}

static esp_err_t init_tinyusb(void) {
  const tinyusb_config_t tusb_cfg = {
      .device_descriptor = NULL,
      .string_descriptor = NULL,
      .string_descriptor_count = 0,
      .external_phy = false,
      .configuration_descriptor = NULL,
      .self_powered = false,
      .vbus_monitor_io = -1,
  };
  esp_err_t err = tinyusb_driver_install(&tusb_cfg);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "tinyusb_driver_install failed: %s", esp_err_to_name(err));
    return err;
  }

  tinyusb_net_config_t net_cfg = {
      .on_recv_callback = usb_ncm_recv_cb,
      .free_tx_buffer = NULL,
      .on_init_callback = usb_ncm_on_init,
      .user_context = &s_driver,
  };
  memcpy(net_cfg.mac_addr, s_driver.usb_mac, 6);
  err = tinyusb_net_init(TINYUSB_USBDEV_0, &net_cfg);
  if (err != ESP_OK) {
    ESP_LOGE(TAG, "tinyusb_net_init failed: %s", esp_err_to_name(err));
    return err;
  }

  // iOS fires DHCP once at the first NETWORK_CONNECTION. Hold link down until
  // the netif and DHCP server are up, then raise it from usb_ncm_maintain().
  set_link_state(false);
  return ESP_OK;
}

bool usb_ncm_start(void) {
  if (s_started) {
    return true;
  }

  esp_err_t err = esp_netif_init();
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "esp_netif_init failed: %s", esp_err_to_name(err));
    return false;
  }
  err = esp_event_loop_create_default();
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "event loop failed: %s", esp_err_to_name(err));
    return false;
  }

  uint8_t base_mac[6] = {0};
  ESP_ERROR_CHECK(esp_read_mac(base_mac, ESP_MAC_EFUSE_FACTORY));
  make_local_mac(s_driver.netif_mac, base_mac, 4);
  make_local_mac(s_driver.usb_mac, base_mac, 5);

  esp_netif_ip_info_t ip_info = {0};
  ip_info.ip.addr = ESP_IP4TOADDR(D400_USB_IP_A, D400_USB_IP_B, D400_USB_IP_C, D400_USB_IP_D);
  ip_info.netmask.addr = ESP_IP4TOADDR(255, 255, 255, 0);
  ip_info.gw.addr = 0;

  esp_netif_inherent_config_t base_cfg = {
      .flags = (esp_netif_flags_t)(ESP_NETIF_DHCP_SERVER | ESP_NETIF_FLAG_AUTOUP),
      .ip_info = &ip_info,
      .get_ip_event = 0,
      .lost_ip_event = 0,
      .if_key = "USB_NCM",
      .if_desc = "usb ncm",
      .route_prio = 10,
  };
  const esp_netif_config_t netif_cfg = {
      .base = &base_cfg,
      .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH,
  };

  esp_netif_t *netif = esp_netif_new(&netif_cfg);
  if (netif == NULL) {
    ESP_LOGE(TAG, "esp_netif_new failed");
    return false;
  }

  s_driver.base.post_attach = usb_ncm_post_attach;
  ESP_ERROR_CHECK(esp_netif_attach(netif, &s_driver));
  ESP_ERROR_CHECK(configure_dhcp(netif));
  esp_netif_action_start(netif, 0, 0, NULL);
  esp_netif_action_connected(netif, 0, 0, NULL);

  err = esp_netif_dhcps_start(netif);
  if (err != ESP_OK && err != ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED) {
    ESP_LOGW(TAG, "dhcps_start: %s", esp_err_to_name(err));
  }

  if (init_tinyusb() != ESP_OK) {
    return false;
  }

  s_started = true;
  ESP_LOGI(TAG, "USB NCM ready at " IPSTR " (no gateway/DNS)", IP2STR(&ip_info.ip));
  return true;
}

void usb_ncm_maintain(void) {
  if (!s_started) {
    return;
  }

  bool mounted = s_mounted;
#if CFG_TUD_ENABLED
  mounted = mounted || tud_mounted();
#endif

  if (mounted && !s_link_up) {
    vTaskDelay(pdMS_TO_TICKS(80));
    set_link_state(true);
  } else if (!mounted && s_link_up) {
    set_link_state(false);
  }
}

bool usb_ncm_host_mounted(void) {
  if (!s_started) {
    return false;
  }
#if CFG_TUD_ENABLED
  return tud_mounted() || s_mounted;
#else
  return s_mounted;
#endif
}

uint8_t usb_ncm_station_count(void) { return usb_ncm_host_mounted() ? 1 : 0; }

#endif  // CONFIG_TINYUSB_NET_MODE_NCM
