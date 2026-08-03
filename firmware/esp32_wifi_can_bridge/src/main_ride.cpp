// Dominar 400 ride-minimal firmware: CAN decode, trip/odometer, binary SSE telemetry.
// No LittleFS, no static web UI — phone app is the dashboard.

#include <Arduino.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <WiFi.h>

#include "bench_metrics.h"
#include "can_ingest.h"
#include "d400_config.h"
#include "sse_transport.h"
#include "telemetry_format.h"
#include "trip_computer.h"

static WebServer gHttp(80);
static uint32_t gSeqNo = 0;
static uint32_t gLastTelemetryMs = 0;
static uint32_t gLastBenchSseSkipped = 0;

static void setupWiFi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  WiFi.softAP(D400_AP_SSID, D400_AP_PASS);

  if (MDNS.begin(D400_MDNS_HOSTNAME)) {
    MDNS.addService("http", "tcp", 80);
  }
}

static TelemetryPublishContext makePublishContext() {
  TelemetryPublishContext ctx;
  ctx.seq = ++gSeqNo;
  ctx.ms = millis();
  ctx.sseSkipped = sseSkippedFrames();
  ctx.sseDropped = sseDroppedClients();
  ctx.softapStations = static_cast<uint8_t>(WiFi.softAPgetStationNum());
  return ctx;
}

static void publishTelemetryOnce() {
  if (millis() - gLastTelemetryMs < D400_TELEMETRY_INTERVAL_MS) return;
  gLastTelemetryMs = millis();

  TelemetryPublishContext ctx = makePublishContext();
  RideTelemetryBinary binary{};
  {
    BenchScope packScope(gBenchPackUs);
    fillRideTelemetryBinary(binary, ctx);
  }
  ssePublishBinary(binary);

  gBenchSseSkippedDelta = sseSkippedFrames() - gLastBenchSseSkipped;
  gLastBenchSseSkipped = sseSkippedFrames();
}

static void handleEvents() {
  sseHandleEvents(gHttp);
}

static void handleHealthJson() {
  processCanFrames();
  maintainOdometer();
  maintainTripComputer();

  char health[512];
  formatHealthJson(health, sizeof(health));
  gHttp.sendHeader("Cache-Control", "no-store");
  gHttp.send(200, "application/json", health);
}

static void handleBenchStatus() {
  char bench[384];
  formatBenchStatusJson(bench, sizeof(bench));
  gHttp.sendHeader("Cache-Control", "no-store");
  gHttp.send(200, "application/json", bench);
}

static void handleTripReset() {
  processCanFrames();
  maintainOdometer();
  maintainTripComputer();

  int slot = 1;
  if (gHttp.hasArg("slot")) slot = gHttp.arg("slot").toInt();
  if (slot < 1 || slot > D400_TRIP_COUNT) {
    gHttp.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_trip\"}");
    return;
  }

  resetTrip(static_cast<uint8_t>(slot - 1));
  bool saved = saveTrip(static_cast<uint8_t>(slot - 1), true);
  gHttp.send(saved || !gOdometerPrefsReady ? 200 : 500,
            "application/json",
            saved || !gOdometerPrefsReady ? "{\"ok\":true}" : "{\"ok\":false,\"error\":\"save_failed\"}");
}

static void handleNotFound() {
  gHttp.send(404, "text/plain", "Not found. Use the phone app.");
}

static void setupHttp() {
  gHttp.on("/events", handleEvents);
  gHttp.on("/health.json", handleHealthJson);
  gHttp.on("/bench/status", handleBenchStatus);
  gHttp.on("/trip/reset", handleTripReset);
  gHttp.on("/health", handleHealthJson);
  gHttp.onNotFound(handleNotFound);
  gHttp.begin();
  sseInit(gHttp);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("D400 ride-minimal binary boot");

  setupOdometer();
  setupTrips();
  setupWiFi();
  setupHttp();
  setupCanBridge();
}

void loop() {
  benchMarkLoopStart();

  gHttp.handleClient();
  sseMaintain();

  {
    BenchScope canScope(gBenchCanDrainUs);
    processCanFrames();
  }

  maintainOdometer();
  maintainTripComputer();
  publishTelemetryOnce();

  benchMarkLoopEnd();
}
