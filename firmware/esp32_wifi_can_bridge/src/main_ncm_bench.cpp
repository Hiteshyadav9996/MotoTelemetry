// USB NCM bench firmware: Ethernet-over-USB gadget + HTTP /health.json.
// Flash this first on the iPhone XR + Lightning camera adapter. Success is
// Settings → Ethernet with 192.168.5.x and Safari opening /health.json.

#include <Arduino.h>
#include <WebServer.h>

#include "usb_ncm.h"

static WebServer gHttp(80);

static void handleHealth() {
  gHttp.sendHeader("Cache-Control", "no-store");
  char body[192];
  snprintf(body, sizeof(body),
           "{\"ok\":true,\"transport\":\"usb-ncm\",\"ip\":\"192.168.5.1\","
           "\"host_mounted\":%s,\"ms\":%lu}",
           usb_ncm_host_mounted() ? "true" : "false",
           static_cast<unsigned long>(millis()));
  gHttp.send(200, "application/json", body);
}

static void handleRoot() {
  gHttp.send(200, "text/plain",
             "D400 USB NCM bench. Open /health.json — expected IP 192.168.5.1");
}

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println("D400 USB NCM bench boot");
  Serial.println("Bridge: http://192.168.5.1/health.json");

  if (!usb_ncm_start()) {
    Serial.println("USB NCM start failed");
  }

  gHttp.on("/", handleRoot);
  gHttp.on("/health.json", handleHealth);
  gHttp.on("/health", handleHealth);
  gHttp.begin();
}

void loop() {
  usb_ncm_maintain();
  gHttp.handleClient();
}
