// Dominar 400 ESP32-S3 + MCP2515 Wi-Fi CAN telemetry bridge.
//
// Hardware target:
// - ESP32-S3-N16R8 dev board.
// - MCP2515 + TJA1050 CAN module wired over SPI.
// - MCP2515 VCC should be 3V3 when connected directly to ESP32 GPIO.
// - CANH/CANL go to the diagnostic adapter only after bench upload/testing.
//
// Passive-only decode test build.
// This variant never transmits CAN frames. It only listens to broadcast ECU
// traffic and uses confirmed/high-confidence passive decodes first. Cluster
// display RPM is bench-confirmed; exact OBD-equivalent RPM remains separate.

#include <Arduino.h>
#include <ESPmDNS.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <SPI.h>
#include <WebServer.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <errno.h>
#include <math.h>
#include <sys/select.h>
#include <lwip/sockets.h>

#if __has_include("wifi_credentials.h")
#include "wifi_credentials.h"
#endif

#ifndef D400_HOTSPOT_SSID
#define D400_HOTSPOT_SSID ""
#endif

#ifndef D400_HOTSPOT_PASSWORD
#define D400_HOTSPOT_PASSWORD ""
#endif

#ifndef D400_HOTSPOT2_SSID
#define D400_HOTSPOT2_SSID ""
#endif

#ifndef D400_HOTSPOT2_PASSWORD
#define D400_HOTSPOT2_PASSWORD ""
#endif

static const char* AP_SSID = "D400Telemetry";
static const char* AP_PASS = "dominar400";
static const char* MDNS_HOSTNAME = "d400telemetry";
static const uint16_t UDP_PORT = 4210;
static const IPAddress UDP_BROADCAST(192, 168, 4, 255);

// Wiring for the MCP2515 module. Change these only if you wired different pins.
static const int SPI_SCK_PIN = 12;
static const int SPI_MISO_PIN = 13;  // MCP2515 SO
static const int SPI_MOSI_PIN = 11;  // MCP2515 SI
static const int CAN_CS_PIN = 10;
static const int CAN_INT_PIN = 9;

// Keep this true for phone/Wi-Fi testing without the bike. Set false when you
// are ready to test real MCP2515 OBD reads.
static const bool WIFI_MOCK_TELEMETRY_ENABLED = false;

// Most blue MCP2515 modules use an 8 MHz crystal. If SPI works but CAN never
// receives anything, check the crystal marking and try 16.
static const uint8_t MCP_CLOCK_MHZ = 8;
// MCP2515 supports up to 10 MHz SPI, but many blue modules/jumper-wire setups
// become flaky near the limit. 8 MHz stayed clean on this bike.
static const uint32_t MCP_SPI_HZ = 8000000UL;
// First live-bike test: listen only, no requests transmitted onto the bike CAN bus.
static const bool CAN_OBD_REQUESTS_ENABLED = false;
static const bool CAN_LISTEN_ONLY = true;
static const uint32_t CAN_BITRATE = 500000;
static const bool MCP_FILTER_IMPORTANT_IDS_ONLY = true;
static const uint32_t PID_TIMEOUT_MS = 35;
static const uint32_t TELEMETRY_INTERVAL_MS = 50;
static const uint32_t PID_INTERVAL_MS = 15;
static const uint8_t OBD_RPM_TEST_SAMPLES = 5;
static const uint32_t OBD_RPM_TEST_TIMEOUT_MS = 90;
static const uint32_t OBD_LOG_DEFAULT_SECONDS = 10;
static const uint32_t OBD_LOG_MAX_SECONDS = 30;
static const uint32_t OBD_LOG_PID_TIMEOUT_MS = 70;
static const char* CAPTURE_FILE_PATH = "/capture.csv";
static const size_t CAPTURE_FLUSH_BYTES = 3072;
static const uint32_t CAPTURE_FLUSH_INTERVAL_MS = 350;
static const uint32_t CAPTURE_RESERVED_FS_BYTES = 384UL * 1024UL;
static const char* CORRELATE_FILE_PATH = "/correlate.csv";
static const size_t CORRELATE_FLUSH_BYTES = 4096;
static const uint32_t CORRELATE_FLUSH_INTERVAL_MS = 250;
static const uint32_t CORRELATE_RESERVED_FS_BYTES = 384UL * 1024UL;
static const uint32_t CORRELATE_MAX_SESSION_MS = 4UL * 60UL * 1000UL;
static const uint32_t CORRELATE_PID_TIMEOUT_MS = 90;
static const uint32_t CORRELATE_PID_COOLDOWN_MS = 45;
static const uint32_t CORRELATE_SUMMARY_INTERVAL_MS = 250;
static const uint8_t CORRELATE_DRAIN_LIMIT = 192;
static const bool SERIAL_TELEMETRY_DEBUG_ENABLED = false;
static const bool SERIAL_RPM_DEBUG_ENABLED = false;
static const bool UDP_TELEMETRY_ENABLED = false;
static const bool SSE_CLIENT_FLUSH_ENABLED = false;
// Skip a telemetry frame instead of blocking when the TCP send window is full.
// Uses a 0-timeout select() + MSG_DONTWAIT send (not availableForWrite(), which
// always returns 0 on Arduino-ESP32 2.x and left the old check inert).
static const bool SSE_BACKPRESSURE_CHECK_ENABLED = true;
// Drop a client that has not accepted a single frame for this long so the app
// reconnects instead of staring at a silently dead stream.
static const uint32_t SSE_STALL_TIMEOUT_MS = 4000;
static const size_t SSE_FRAME_BUF_MAX = 2048;
static const bool DROP_EXTENDED_FRAMES_IN_FILTERED_MODE = true;
static const uint32_t CAN_STALE_REINIT_MS = 2000;
static const uint32_t CAN_REINIT_COOLDOWN_MS = 3000;
static const uint32_t ODOMETER_INITIAL_METERS = 53988UL * 1000UL;
static const uint32_t ODOMETER_SAVE_DISTANCE_METERS = 100;
static const uint32_t ODOMETER_SAVE_INTERVAL_MS = 30000;
static const uint32_t ODOMETER_SPEED_MAX_AGE_MS = 500;
static const uint32_t ODOMETER_MAX_INTEGRATION_GAP_MS = 1000;
static const float ODOMETER_MIN_SPEED_KPH = 1.0f;
static const char* ODOMETER_PREF_NAMESPACE = "d400";
static const char* ODOMETER_PREF_METERS_KEY = "odo_m";
static const uint8_t TRIP_COUNT = 2;
static const uint32_t TRIP_TICK_MS = 1000;
static const uint32_t TRIP_SAVE_DISTANCE_METERS = 100;
static const uint32_t TRIP_SAVE_INTERVAL_MS = 30000;
static const uint32_t TRIP_SPEED_MAX_AGE_MS = 500;
static const uint32_t TRIP_RPM_MAX_AGE_MS = 500;
static const uint32_t TRIP_SENSOR_MAX_AGE_MS = 1500;
static const float TRIP_ENGINE_RUNNING_RPM = 500.0f;
static const float TRIP_DISPLACEMENT_M3 = 0.0003733f;
static const float TRIP_GAS_CONSTANT_R = 287.05f;
static const float TRIP_FUEL_DENSITY_G_L = 740.0f;
static const float TRIP_STOICH_AFR = 14.7f;
static const float TRIP_VE_BASE = 0.60f;
static const float TRIP_VE_TPS_SCALE = 0.25f;
static const float PASSIVE_TPS_IDLE_OBD_PCT = 27.0f * 100.0f / 255.0f;
static const float PASSIVE_TPS_ABS_SCALE = (100.0f - PASSIVE_TPS_IDLE_OBD_PCT) / 255.0f;
static const char* FIRMWARE_VARIANT = "passive-only";
static const float PASSIVE_MAP_OFFSET_KPA = 1.0f;
static const float PASSIVE_COOLANT_SCALE = 0.099314f;
static const float PASSIVE_COOLANT_OFFSET = 2983.421676f;
static const float PASSIVE_IAT_SCALE = 0.095760f;
static const float PASSIVE_IAT_OFFSET = 34.038803f;
static const float PASSIVE_301_TACH_RPM_SCALE = 40.0f;
static const float PASSIVE_310_BUCKET_RPM_SCALE = 100.0f;
static const float PASSIVE_30C_SPEED_KPH_SCALE = 118.0f;
// The cluster display-speed signal over-counted a measured 17.1 km ride as
// 17.9 km. Keep display speed unchanged, but correct integrated distance.
static const float PASSIVE_DISTANCE_CALIBRATION = 17.1f / 17.9f;
static const float PASSIVE_303_BATTERY_V_SCALE = 0.1f;
static const uint32_t PASSIVE_RPM_PAIR_MAX_AGE_MS = 160;

WiFiUDP udp;
WebServer http(80);
Preferences odometerPrefs;
// WiFiClient refcounts its socket, so this copy keeps the stream alive after
// WebServer releases its own reference. loop() pumps it; nothing blocks.
WiFiClient sseClient;
bool sseClientActive = false;
uint32_t sseLastSendMs = 0;
uint32_t sseLastAcceptedMs = 0;
uint32_t sseSkippedFrames = 0;
uint32_t sseDroppedClients = 0;
bool mdnsStarted = false;
uint32_t seqNo = 0;
uint32_t txRequests = 0;
uint32_t rxFrames = 0;
uint32_t rxResponses = 0;
uint32_t pidTimeouts = 0;
uint32_t mcpRxOverflowEvents = 0;
uint32_t lastMcpRxOverflowMs = 0;
uint32_t mcpReinitAttempts = 0;
uint32_t lastMcpReinitMs = 0;
uint32_t droppedCorruptFrames = 0;
uint32_t lastCanFrameMs = 0;
uint32_t lastGoodResponseMs = 0;
bool canReady = false;
bool fsReady = false;
bool odometerPrefsReady = false;
bool odometerWasMoving = false;
uint32_t odometerMeters = ODOMETER_INITIAL_METERS;
uint32_t odometerLastSavedMeters = ODOMETER_INITIAL_METERS;
uint32_t odometerLastUpdateMs = 0;
uint32_t odometerLastSaveMs = 0;
uint32_t odometerSaveCount = 0;
float odometerFractionMeters = 0.0f;

struct TripState {
  uint32_t distanceMeters = 0;
  uint32_t fuelMilliLiters = 0;
  uint32_t seconds = 0;
  uint32_t savedDistanceMeters = 0;
  uint32_t savedFuelMilliLiters = 0;
  uint32_t savedSeconds = 0;
  uint32_t saveCount = 0;
  float distanceFractionMeters = 0.0f;
  float fuelFractionMilliLiters = 0.0f;
};

TripState trips[TRIP_COUNT];
uint32_t tripLastTickMs = 0;
uint32_t tripLastSaveMs = 0;
bool tripWasActive = false;

struct CanFrame {
  uint32_t id = 0;
  bool extended = false;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

struct Telemetry {
  float rpm = NAN;
  float coolant = NAN;
  float iat = NAN;
  float map = NAN;
  float tps = NAN;
  float tpsAbs = NAN;
  float speed = NAN;
  float vbatt = NAN;
};

Telemetry telemetry;

String estimatedGear();
bool applyPassiveCanFrame(const CanFrame& frame);

static const size_t CAN_RECENT_COUNT = 24;
static const size_t CAN_ID_STATS_COUNT = 48;

struct RecentCanFrame {
  uint32_t ms = 0;
  uint32_t id = 0;
  bool extended = false;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

struct CanIdStat {
  bool used = false;
  uint32_t id = 0;
  bool extended = false;
  uint32_t count = 0;
  uint32_t lastMs = 0;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

RecentCanFrame recentCanFrames[CAN_RECENT_COUNT];
CanIdStat canIdStats[CAN_ID_STATS_COUNT];
size_t recentCanWriteIndex = 0;
uint32_t recentCanStored = 0;
bool hasPassiveRpm = false;
uint16_t lastPassiveRpmRaw = 0;
uint32_t lastPassiveRpmFrameId = 0;
uint32_t lastPassiveRpmMs = 0;
bool hasPassive301Tach = false;
uint8_t lastPassive301TachRaw = 0;
uint32_t lastPassive301TachMs = 0;
bool hasPassive302RpmCompanion = false;
uint8_t lastPassive302RpmB1 = 0;
uint8_t lastPassive302RpmB3 = 0;
uint8_t lastPassive302RpmB7 = 0;
uint32_t lastPassive302RpmCompanionMs = 0;
bool hasPassiveTps = false;
uint8_t lastPassiveTpsRaw = 0;
float lastPassiveTpsGrip = NAN;
float lastPassiveTpsAbs = NAN;
uint32_t lastPassiveTpsMs = 0;
bool hasPassiveCoolant = false;
int16_t lastPassiveCoolantRaw = 0;
uint32_t lastPassiveCoolantMs = 0;
bool hasPassiveIat = false;
uint8_t lastPassiveIatRaw = 0;
uint32_t lastPassiveIatMs = 0;
bool hasPassiveMap = false;
uint8_t lastPassiveMapRaw = 0;
uint32_t lastPassiveMapMs = 0;
bool hasPassiveGear = false;
uint8_t lastPassiveGearRaw = 0xFF;
uint32_t lastPassiveGearMs = 0;
bool hasPassiveSpeed = false;
uint16_t lastPassiveSpeedRaw = 0;
uint32_t lastPassiveSpeedMs = 0;
bool hasPassiveBattery = false;
uint8_t lastPassiveBatteryRaw = 0;
uint32_t lastPassiveBatteryMs = 0;
bool captureActive = false;
File captureFile;
String captureBuffer;
String captureStage = "idle";
uint32_t captureStartedMs = 0;
uint32_t captureLastFlushMs = 0;
uint32_t captureRows = 0;
uint32_t captureMarks = 0;
uint32_t captureDroppedRows = 0;
uint32_t captureFileBytes = 0;
uint32_t captureMaxBytes = 0;
uint32_t captureStartRxFrames = 0;
bool correlateActive = false;
File correlateFile;
String correlateBuffer;
String correlateStage = "idle";
uint32_t correlateStartedMs = 0;
uint32_t correlateLastFlushMs = 0;
uint32_t correlateRows = 0;
uint32_t correlateFrameRows = 0;
uint32_t correlateObdRows = 0;
uint32_t correlateObdOk = 0;
uint32_t correlateObdFail = 0;
uint32_t correlateSummaryRows = 0;
uint32_t correlateMarks = 0;
uint32_t correlateDroppedRows = 0;
uint32_t correlateFileBytes = 0;
uint32_t correlateMaxBytes = 0;
uint32_t correlateStartRxFrames = 0;
uint32_t correlateStartTxRequests = 0;
uint32_t correlateStartRxResponses = 0;
uint32_t correlateStartPidTimeouts = 0;
uint32_t correlateStartMcpRxOverflows = 0;
uint32_t correlateLastPidRequestMs = 0;
uint32_t correlateLastSummaryMs = 0;
uint32_t correlateLastOverflowLogMs = 0;
uint8_t correlateNextPidIndex = 0;

const char TEST_PAGE[] PROGMEM = R"rawliteral(
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <title>D400 Telemetry Test</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #05080b; color: #f7f4ea; }
    main { width: min(92vw, 720px); }
    h1 { margin: 0 0 8px; font-size: clamp(26px, 7vw, 54px); letter-spacing: 0; }
    .status { color: #8f9aaa; font-weight: 800; letter-spacing: .16em; text-transform: uppercase; }
    .row { display: flex; align-items: baseline; justify-content: space-between; gap: 22px; margin-top: 18px; border-bottom: 1px solid #26303a; }
    .label { color: #8f9aaa; font-weight: 900; letter-spacing: .18em; }
    .value { font-size: clamp(34px, 12vw, 92px); font-weight: 1000; font-style: italic; }
    .unit { font-size: clamp(16px, 4vw, 28px); color: #c6c9c8; }
    pre { overflow: auto; padding: 12px; border: 1px solid #26303a; color: #9aa5ae; }
  </style>
</head>
<body>
  <main>
    <div class="status" id="status">Connecting</div>
    <h1>D400 ESP32 Mock</h1>
    <div class="row"><span class="label">RPM</span><span><span class="value" id="rpm">--</span><span class="unit"> rpm</span></span></div>
    <div class="row"><span class="label">Speed</span><span><span class="value" id="speed">--</span><span class="unit"> km/h</span></span></div>
    <div class="row"><span class="label">Temp</span><span><span class="value" id="temp">--</span><span class="unit"> C</span></span></div>
    <div class="row"><span class="label">TPS</span><span><span class="value" id="tps">--</span><span class="unit"> %</span></span></div>
    <pre id="raw">{}</pre>
  </main>
  <script>
    async function tick() {
      try {
        const res = await fetch('/telemetry.json', { cache: 'no-store' });
        const t = await res.json();
        document.getElementById('status').textContent = `packet #${t.seq} from ${t.source}`;
        document.getElementById('rpm').textContent = Math.round(t.rpm ?? 0);
        document.getElementById('speed').textContent = Math.round(t.speed_kph ?? t.speed ?? 0);
        document.getElementById('temp').textContent = Number(t.engine_temp_c ?? t.coolant_c ?? 0).toFixed(1);
        document.getElementById('tps').textContent = Number(t.tps_pct ?? t.tps ?? 0).toFixed(1);
        document.getElementById('raw').textContent = JSON.stringify(t, null, 2);
      } catch (err) {
        document.getElementById('status').textContent = 'waiting for ESP32';
      }
    }
    tick();
    setInterval(tick, 180);
  </script>
</body>
</html>
)rawliteral";

const char CAPTURE_PAGE[] PROGMEM = R"rawliteral(
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <title>D400 CAN Capture</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; background: #070a0e; color: #f5f2e9; }
    main { width: min(920px, calc(100vw - 28px)); margin: 0 auto; padding: 18px 0 28px; }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    h2 { margin: 22px 0 10px; font-size: 15px; color: #9ba5ad; letter-spacing: .18em; text-transform: uppercase; }
    p { margin: 7px 0; color: #b9c0c7; line-height: 1.35; }
    .status { display: grid; gap: 8px; grid-template-columns: repeat(2, minmax(0, 1fr)); margin: 14px 0; }
    .box { border: 1px solid #26313b; background: #101720; padding: 10px 12px; border-radius: 8px; }
    .k { display: block; color: #85909a; font-size: 11px; font-weight: 900; letter-spacing: .18em; text-transform: uppercase; }
    .v { display: block; margin-top: 4px; font-size: 18px; font-weight: 900; }
    .buttons { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
    button, a.action { appearance: none; border: 1px solid #34404b; background: #151d26; color: #f5f2e9; min-height: 44px; border-radius: 8px; font: inherit; font-weight: 850; text-decoration: none; display: grid; place-items: center; text-align: center; padding: 8px 10px; }
    button.primary { border-color: #d99c22; background: #2a2112; }
    button.danger { border-color: #a94747; background: #241313; }
    button.good { border-color: #3c8f67; background: #122019; }
    .wide { grid-column: 1 / -1; }
    pre { white-space: pre-wrap; overflow: auto; border: 1px solid #26313b; background: #05080b; padding: 10px; min-height: 42px; border-radius: 8px; color: #aab3bb; }
    @media (orientation: landscape) {
      main { width: min(1050px, calc(100vw - 36px)); padding-top: 12px; }
      .buttons { grid-template-columns: repeat(4, minmax(0, 1fr)); }
      .status { grid-template-columns: repeat(4, minmax(0, 1fr)); }
    }
  </style>
</head>
<body>
<main>
  <h1>D400 Passive CAN Capture</h1>
  <p>Use this page only for decoding sessions. It writes raw passive CAN frames to LittleFS with stage markers.</p>
  <div class="status">
    <div class="box"><span class="k">State</span><span class="v" id="active">--</span></div>
    <div class="box"><span class="k">Stage</span><span class="v" id="stage">--</span></div>
    <div class="box"><span class="k">Rows</span><span class="v" id="rows">--</span></div>
    <div class="box"><span class="k">Size</span><span class="v" id="bytes">--</span></div>
    <div class="box"><span class="k">CAN</span><span class="v" id="can">--</span></div>
    <div class="box"><span class="k">RX Delta</span><span class="v" id="rxdelta">--</span></div>
  </div>

  <div class="buttons">
    <button class="primary" onclick="startCapture()">Start New Capture</button>
    <button class="danger" onclick="stopCapture()">Stop Capture</button>
    <a class="action good" href="/capture/download">Download CSV</a>
    <button onclick="mark('note','checkpoint')">Checkpoint</button>
  </div>

  <h2>1 Baseline</h2>
  <div class="buttons">
    <button class="wide" onclick="mark('baseline','ignition_on_engine_off_still')">Ignition ON, Engine OFF, Still</button>
  </div>

  <h2>2 Switches</h2>
  <div class="buttons">
    <button onclick="mark('side_stand','side_stand_down')">Side Stand Down</button>
    <button onclick="mark('side_stand','side_stand_up')">Side Stand Up</button>
    <button onclick="mark('clutch','clutch_released')">Clutch Released</button>
    <button onclick="mark('clutch','clutch_pulled')">Clutch Pulled</button>
    <button onclick="mark('kill_switch','kill_switch_run')">Kill Run</button>
    <button onclick="mark('kill_switch','kill_switch_off')">Kill Off</button>
  </div>

  <h2>3 Throttle, Engine OFF</h2>
  <div class="buttons">
    <button onclick="mark('throttle','throttle_closed')">Closed</button>
    <button onclick="mark('throttle','throttle_25')">25%</button>
    <button onclick="mark('throttle','throttle_50')">50%</button>
    <button onclick="mark('throttle','throttle_100')">100%</button>
    <button class="wide" onclick="mark('throttle','throttle_released')">Released</button>
  </div>

  <h2>4 Rear Wheel, Engine OFF</h2>
  <div class="buttons">
    <button onclick="mark('rear_wheel','wheel_stopped')">Stopped</button>
    <button onclick="mark('rear_wheel','wheel_slow')">Slow</button>
    <button onclick="mark('rear_wheel','wheel_medium')">Medium</button>
    <button onclick="mark('rear_wheel','wheel_fast')">Fast</button>
  </div>

  <h2>5 Gear, Engine OFF</h2>
  <div class="buttons">
    <button onclick="mark('gear','gear_N')">N</button>
    <button onclick="mark('gear','gear_1')">1</button>
    <button onclick="mark('gear','gear_2')">2</button>
    <button onclick="mark('gear','gear_3')">3</button>
    <button onclick="mark('gear','gear_4')">4</button>
    <button onclick="mark('gear','gear_5')">5</button>
    <button onclick="mark('gear','gear_6')">6</button>
  </div>

  <h2>6 Engine Running</h2>
  <div class="buttons">
    <button onclick="mark('idle_warmup','idle_start')">Idle Start</button>
    <button onclick="mark('idle_warmup','idle_warming')">Idle Warming</button>
    <button onclick="mark('rpm','rpm_idle')">RPM Idle</button>
    <button onclick="mark('rpm','rpm_2000')">RPM 2000</button>
    <button onclick="mark('rpm','rpm_3000')">RPM 3000</button>
    <button onclick="mark('rpm','rpm_4000')">RPM 4000</button>
    <button class="wide" onclick="mark('rpm','rpm_release')">RPM Release</button>
  </div>

  <h2>Log</h2>
  <pre id="log">Ready.</pre>
</main>
<script>
  const $ = (id) => document.getElementById(id);
  function kb(n) { return n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`; }
  async function api(path) {
    const res = await fetch(path, { cache: 'no-store' });
    const text = await res.text();
    let body = text;
    try { body = JSON.parse(text); } catch (_) {}
    $('log').textContent = typeof body === 'string' ? body : JSON.stringify(body, null, 2);
    await refresh();
    return body;
  }
  async function startCapture() { await api('/capture/start?stage=baseline'); }
  async function stopCapture() { await api('/capture/stop'); }
  async function mark(stage, label) {
    await api(`/capture/mark?stage=${encodeURIComponent(stage)}&label=${encodeURIComponent(label)}`);
  }
  async function refresh() {
    try {
      const res = await fetch('/capture/status', { cache: 'no-store' });
      const s = await res.json();
      $('active').textContent = s.active ? 'Recording' : 'Stopped';
      $('stage').textContent = s.stage || '--';
      $('rows').textContent = `${s.rows || 0} / marks ${s.marks || 0}`;
      $('bytes').textContent = `${kb(s.bytes || 0)} / ${kb(s.max_bytes || 0)}`;
      $('can').textContent = s.can_ready ? `OK ${s.last_can_age_ms ?? '--'}ms` : 'Not ready';
      $('rxdelta').textContent = `${s.rx_frames_since_start || 0}`;
    } catch (err) {
      $('active').textContent = 'Offline';
    }
  }
  refresh();
  setInterval(refresh, 1000);
</script>
</body>
</html>
)rawliteral";

const char CORRELATE_PAGE[] PROGMEM = R"rawliteral(
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <title>D400 Correlate</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; min-height: 100vh; background: #06090d; color: #f6f2e8; }
    main { width: min(960px, calc(100vw - 28px)); margin: 0 auto; padding: 16px 0 28px; }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    h2 { margin: 20px 0 10px; font-size: 14px; color: #9aa4ad; letter-spacing: .18em; text-transform: uppercase; }
    p { margin: 7px 0; color: #bbc3c9; line-height: 1.35; }
    .status { display: grid; gap: 8px; grid-template-columns: repeat(2, minmax(0, 1fr)); margin: 14px 0; }
    .box { border: 1px solid #293541; background: #101821; padding: 10px 12px; border-radius: 8px; }
    .k { display: block; color: #87939d; font-size: 11px; font-weight: 900; letter-spacing: .18em; text-transform: uppercase; }
    .v { display: block; margin-top: 4px; font-size: 18px; font-weight: 900; }
    .buttons { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
    button, a.action { appearance: none; border: 1px solid #34424f; background: #151f29; color: #f6f2e8; min-height: 46px; border-radius: 8px; font: inherit; font-weight: 850; text-decoration: none; display: grid; place-items: center; text-align: center; padding: 8px 10px; }
    button.primary { border-color: #daa02a; background: #2a2112; }
    button.danger { border-color: #ad4a4a; background: #251414; }
    button.good, a.good { border-color: #3c9369; background: #12221a; }
    button.warn { border-color: #b98733; background: #261d10; }
    .wide { grid-column: 1 / -1; }
    pre { white-space: pre-wrap; overflow: auto; border: 1px solid #293541; background: #05080b; padding: 10px; min-height: 42px; border-radius: 8px; color: #aab4bd; }
    @media (orientation: landscape) {
      main { width: min(1100px, calc(100vw - 36px)); padding-top: 12px; }
      .buttons { grid-template-columns: repeat(4, minmax(0, 1fr)); }
      .status { grid-template-columns: repeat(4, minmax(0, 1fr)); }
    }
  </style>
</head>
<body>
<main>
  <h1>D400 Passive + OBD Correlation</h1>
  <p>Use this only while stationary. It logs passive CAN frames continuously and inserts slow OBD PID samples into the same timestamped CSV.</p>

  <div class="status">
    <div class="box"><span class="k">State</span><span class="v" id="active">--</span></div>
    <div class="box"><span class="k">Stage</span><span class="v" id="stage">--</span></div>
    <div class="box"><span class="k">Rows</span><span class="v" id="rows">--</span></div>
    <div class="box"><span class="k">OBD</span><span class="v" id="obd">--</span></div>
    <div class="box"><span class="k">Overflow</span><span class="v" id="overflow">--</span></div>
    <div class="box"><span class="k">File</span><span class="v" id="bytes">--</span></div>
    <div class="box"><span class="k">CAN</span><span class="v" id="can">--</span></div>
    <div class="box"><span class="k">Elapsed</span><span class="v" id="elapsed">--</span></div>
  </div>

  <div class="buttons">
    <button class="primary" onclick="startCorrelation()">Start Session</button>
    <button class="danger" onclick="stopCorrelation()">Stop Session</button>
    <a class="action good" href="/correlate/download">Download CSV</a>
    <button onclick="mark('checkpoint')">Checkpoint</button>
  </div>

  <h2>RPM Hold Stages</h2>
  <div class="buttons">
    <button class="good" onclick="mark('rpm_idle')">Idle</button>
    <button onclick="mark('rpm_2000')">RPM 2000</button>
    <button onclick="mark('rpm_3000')">RPM 3000</button>
    <button onclick="mark('rpm_4000')">RPM 4000</button>
    <button onclick="mark('rpm_5000')">RPM 5000</button>
    <button class="wide warn" onclick="mark('rpm_release')">Release / Back to Idle</button>
  </div>

  <h2>Log</h2>
  <pre id="log">Ready.</pre>
</main>
<script>
  const $ = (id) => document.getElementById(id);
  function kb(n) { return n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`; }
  function sec(ms) { return `${Math.round((ms || 0) / 1000)}s`; }
  async function api(path) {
    const res = await fetch(path, { cache: 'no-store' });
    const text = await res.text();
    let body = text;
    try { body = JSON.parse(text); } catch (_) {}
    $('log').textContent = typeof body === 'string' ? body : JSON.stringify(body, null, 2);
    await refresh();
    return body;
  }
  async function startCorrelation() { await api('/correlate/start?stage=rpm_idle'); }
  async function stopCorrelation() { await api('/correlate/stop'); }
  async function mark(stage) { await api(`/correlate/mark?stage=${encodeURIComponent(stage)}`); }
  async function refresh() {
    try {
      const res = await fetch('/correlate/status', { cache: 'no-store' });
      const s = await res.json();
      $('active').textContent = s.active ? 'Recording' : 'Stopped';
      $('stage').textContent = s.stage || '--';
      $('rows').textContent = `${s.rows || 0} / F ${s.frame_rows || 0}`;
      $('obd').textContent = `${s.obd_ok || 0} ok / ${s.obd_fail || 0} fail`;
      $('overflow').textContent = `${s.overflow_delta || 0}`;
      $('bytes').textContent = `${kb(s.bytes || 0)} / ${kb(s.max_bytes || 0)}`;
      $('can').textContent = s.can_ready ? `OK ${s.last_can_age_ms ?? '--'}ms` : 'Not ready';
      $('elapsed').textContent = sec(s.elapsed_ms);
    } catch (err) {
      $('active').textContent = 'Offline';
    }
  }
  refresh();
  setInterval(refresh, 1000);
</script>
</body>
</html>
)rawliteral";

class Mcp2515 {
 public:
  bool begin() {
    pinMode(CAN_CS_PIN, OUTPUT);
    digitalWrite(CAN_CS_PIN, HIGH);
    pinMode(CAN_INT_PIN, INPUT_PULLUP);

    SPI.begin(SPI_SCK_PIN, SPI_MISO_PIN, SPI_MOSI_PIN, CAN_CS_PIN);
    SPI.setFrequency(MCP_SPI_HZ);

    reset();
    uint8_t mode = readRegister(CANSTAT) & MODE_MASK;
    if (mode != MODE_CONFIG) {
      Serial.printf("MCP2515 probe failed. CANSTAT=0x%02X\n", readRegister(CANSTAT));
      return false;
    }
    return true;
  }

  bool configure(bool listenOnly) {
    reset();
    if (!setMode(MODE_CONFIG)) return false;

    if (MCP_CLOCK_MHZ == 8 && CAN_BITRATE == 500000) {
      writeRegister(CNF1, 0x00);
      writeRegister(CNF2, 0x90);
      writeRegister(CNF3, 0x82);
    } else if (MCP_CLOCK_MHZ == 8 && CAN_BITRATE == 250000) {
      writeRegister(CNF1, 0x00);
      writeRegister(CNF2, 0xB1);
      writeRegister(CNF3, 0x85);
    } else if (MCP_CLOCK_MHZ == 16 && CAN_BITRATE == 500000) {
      writeRegister(CNF1, 0x00);
      writeRegister(CNF2, 0xF0);
      writeRegister(CNF3, 0x86);
    } else if (MCP_CLOCK_MHZ == 16 && CAN_BITRATE == 250000) {
      writeRegister(CNF1, 0x41);
      writeRegister(CNF2, 0xF1);
      writeRegister(CNF3, 0x85);
    } else {
      Serial.println("Unsupported MCP_CLOCK_MHZ/CAN_BITRATE combination.");
      return false;
    }

    // In riding mode, filter down to decoded IDs so the MCP2515's tiny RX
    // buffers are not flooded by frames the dashboard never uses.
    if (MCP_FILTER_IMPORTANT_IDS_ONLY) {
      configureImportantReceiveFilters();
    } else {
      writeRegister(RXB0CTRL, 0x64);  // receive any, rollover to RXB1
      writeRegister(RXB1CTRL, 0x60);  // receive any
    }
    writeRegister(CANINTE, 0x03);   // RX0IE + RX1IE
    writeRegister(CANINTF, 0x00);
    writeRegister(EFLG, 0x00);

    return setMode(listenOnly ? MODE_LISTEN : MODE_NORMAL);
  }

  bool sendFrame(const CanFrame& frame) {
    if (frame.extended || frame.dlc > 8) return false;
    if (readRegister(TXB0CTRL) & TXREQ) abortPendingTx();
    if (readRegister(TXB0CTRL) & TXREQ) return false;

    uint8_t sidH = static_cast<uint8_t>(frame.id >> 3);
    uint8_t sidL = static_cast<uint8_t>((frame.id & 0x07) << 5);

    writeRegister(TXB0SIDH, sidH);
    writeRegister(TXB0SIDL, sidL);
    writeRegister(TXB0EID8, 0x00);
    writeRegister(TXB0EID0, 0x00);
    writeRegister(TXB0DLC, frame.dlc & 0x0F);
    for (uint8_t i = 0; i < frame.dlc; i++) {
      writeRegister(TXB0D0 + i, frame.data[i]);
    }

    command(RTS_TXB0);
    txRequests++;
    return true;
  }

  bool readFrame(CanFrame& frame) {
    uint8_t flags = readRegister(CANINTF);
    if (flags & RX0IF) {
      readRxBuffer(RXB0SIDH, frame);
      bitModify(CANINTF, RX0IF, 0x00);
      return true;
    }
    if (flags & RX1IF) {
      readRxBuffer(RXB1SIDH, frame);
      bitModify(CANINTF, RX1IF, 0x00);
      return true;
    }
    return false;
  }

  uint8_t errorFlags() {
    return readRegister(EFLG);
  }

  uint8_t rxOverflowFlags() {
    return readRegister(EFLG) & (RX0OVR | RX1OVR);
  }

  void clearRxOverflowFlags() {
    bitModify(EFLG, RX0OVR | RX1OVR, 0x00);
  }

  uint8_t status() {
    select();
    SPI.transfer(READ_STATUS);
    uint8_t value = SPI.transfer(0x00);
    deselect();
    return value;
  }

 private:
  static const uint8_t RESET = 0xC0;
  static const uint8_t READ = 0x03;
  static const uint8_t WRITE = 0x02;
  static const uint8_t BIT_MODIFY = 0x05;
  static const uint8_t READ_STATUS = 0xA0;
  static const uint8_t RTS_TXB0 = 0x81;

  static const uint8_t CANSTAT = 0x0E;
  static const uint8_t CANCTRL = 0x0F;
  static const uint8_t CNF3 = 0x28;
  static const uint8_t CNF2 = 0x29;
  static const uint8_t CNF1 = 0x2A;
  static const uint8_t CANINTE = 0x2B;
  static const uint8_t CANINTF = 0x2C;
  static const uint8_t EFLG = 0x2D;

  static const uint8_t RXF0SIDH = 0x00;
  static const uint8_t RXF1SIDH = 0x04;
  static const uint8_t RXF2SIDH = 0x08;
  static const uint8_t RXF3SIDH = 0x10;
  static const uint8_t RXF4SIDH = 0x14;
  static const uint8_t RXF5SIDH = 0x18;
  static const uint8_t RXM0SIDH = 0x20;
  static const uint8_t RXM1SIDH = 0x24;

  static const uint8_t TXB0CTRL = 0x30;
  static const uint8_t TXB0SIDH = 0x31;
  static const uint8_t TXB0SIDL = 0x32;
  static const uint8_t TXB0EID8 = 0x33;
  static const uint8_t TXB0EID0 = 0x34;
  static const uint8_t TXB0DLC = 0x35;
  static const uint8_t TXB0D0 = 0x36;

  static const uint8_t RXB0CTRL = 0x60;
  static const uint8_t RXB0SIDH = 0x61;
  static const uint8_t RXB1CTRL = 0x70;
  static const uint8_t RXB1SIDH = 0x71;

  static const uint8_t RX0IF = 0x01;
  static const uint8_t RX1IF = 0x02;
  static const uint8_t RX0OVR = 0x40;
  static const uint8_t RX1OVR = 0x80;
  static const uint8_t TXREQ = 0x08;
  static const uint8_t ABAT = 0x10;

  static const uint8_t MODE_MASK = 0xE0;
  static const uint8_t MODE_NORMAL = 0x00;
  static const uint8_t MODE_LISTEN = 0x60;
  static const uint8_t MODE_CONFIG = 0x80;

  void select() {
    digitalWrite(CAN_CS_PIN, LOW);
  }

  void deselect() {
    digitalWrite(CAN_CS_PIN, HIGH);
  }

  void command(uint8_t instruction) {
    select();
    SPI.transfer(instruction);
    deselect();
  }

  void reset() {
    command(RESET);
    delay(10);
  }

  uint8_t readRegister(uint8_t address) {
    select();
    SPI.transfer(READ);
    SPI.transfer(address);
    uint8_t value = SPI.transfer(0x00);
    deselect();
    return value;
  }

  void writeRegister(uint8_t address, uint8_t value) {
    select();
    SPI.transfer(WRITE);
    SPI.transfer(address);
    SPI.transfer(value);
    deselect();
  }

  void bitModify(uint8_t address, uint8_t mask, uint8_t value) {
    select();
    SPI.transfer(BIT_MODIFY);
    SPI.transfer(address);
    SPI.transfer(mask);
    SPI.transfer(value);
    deselect();
  }

  void writeStandardIdRegisters(uint8_t base, uint16_t id) {
    id &= 0x07FF;
    writeRegister(base, static_cast<uint8_t>(id >> 3));
    writeRegister(base + 1, static_cast<uint8_t>((id & 0x07) << 5));
    writeRegister(base + 2, 0x00);
    writeRegister(base + 3, 0x00);
  }

  void configureImportantReceiveFilters() {
    writeStandardIdRegisters(RXM0SIDH, 0x07FF);
    writeStandardIdRegisters(RXM1SIDH, 0x07FF);

    // Keep gear/speed on RXB0 so heavy ECU-frame traffic cannot bury the two
    // values the rider notices most immediately.
    writeStandardIdRegisters(RXF0SIDH, 0x447);
    writeStandardIdRegisters(RXF1SIDH, 0x30C);

    writeStandardIdRegisters(RXF2SIDH, 0x301);  // RPM + TPS
    writeStandardIdRegisters(RXF3SIDH, 0x302);  // temp + IAT + MAP + RPM companion
    writeStandardIdRegisters(RXF4SIDH, 0x303);  // candidate battery voltage
    writeStandardIdRegisters(RXF5SIDH, 0x303);  // candidate battery voltage

    writeRegister(RXB0CTRL, 0x00);  // RXB0 filters only, no rollover
    writeRegister(RXB1CTRL, 0x00);  // RXB1 filters only
  }

  bool setMode(uint8_t mode) {
    bitModify(CANCTRL, MODE_MASK, mode);
    uint32_t start = millis();
    while (millis() - start < 100) {
      if ((readRegister(CANSTAT) & MODE_MASK) == mode) return true;
      delay(2);
    }
    Serial.printf("MCP2515 mode switch failed. Wanted=0x%02X CANSTAT=0x%02X\n",
                  mode, readRegister(CANSTAT));
    return false;
  }

  void abortPendingTx() {
    bitModify(CANCTRL, ABAT, ABAT);
    delay(2);
    bitModify(CANCTRL, ABAT, 0x00);
    bitModify(TXB0CTRL, TXREQ, 0x00);
  }

  void readRxBuffer(uint8_t base, CanFrame& frame) {
    uint8_t rxBytes[13] = {0};
    select();
    SPI.transfer(READ);
    SPI.transfer(base);
    for (uint8_t i = 0; i < sizeof(rxBytes); i++) {
      rxBytes[i] = SPI.transfer(0x00);
    }
    deselect();

    uint8_t sidH = rxBytes[0];
    uint8_t sidL = rxBytes[1];
    uint8_t eid8 = rxBytes[2];
    uint8_t eid0 = rxBytes[3];
    uint8_t dlc = rxBytes[4] & 0x0F;

    frame.extended = (sidL & 0x08) != 0;
    if (frame.extended) {
      frame.id = (static_cast<uint32_t>(sidH) << 21) |
                 (static_cast<uint32_t>(sidL & 0xE0) << 13) |
                 (static_cast<uint32_t>(sidL & 0x03) << 16) |
                 (static_cast<uint32_t>(eid8) << 8) |
                 eid0;
    } else {
      frame.id = (static_cast<uint32_t>(sidH) << 3) | (sidL >> 5);
    }

    frame.dlc = dlc > 8 ? 8 : dlc;
    for (uint8_t i = 0; i < frame.dlc; i++) {
      frame.data[i] = rxBytes[5 + i];
    }
    rxFrames++;
  }
};

Mcp2515 can;

struct PidRequest {
  uint8_t pid;
  uint8_t neededBytes;
};

static const PidRequest PID_SCHEDULE[] = {
  {0x0C, 2},  // RPM
  {0x0D, 1},  // speed
  {0x11, 1},  // throttle
  {0x0C, 2},  // RPM again for faster tach updates
  {0x05, 1},  // coolant
  {0x0B, 1},  // manifold pressure
  {0x0F, 1},  // intake air temp
  {0x42, 2},  // ECU voltage
};

struct ObdLogPid {
  uint8_t pid;
  uint8_t neededBytes;
  const char* name;
};

static const ObdLogPid OBD_LOG_PIDS[] = {
  {0x0C, 2, "rpm"},
  {0x11, 1, "tps"},
  {0x05, 1, "coolant"},
  {0x0F, 1, "iat"},
  {0x0D, 1, "speed"},
  {0x0B, 1, "map"},
  {0x42, 2, "ecu_voltage"},
};

struct CorrelatePid {
  uint8_t pid;
  uint8_t neededBytes;
  const char* name;
  const char* unit;
  uint32_t intervalMs;
  uint32_t lastRequestMs;
};

CorrelatePid CORRELATE_PIDS[] = {
  {0x0C, 2, "rpm", "rpm", 250, 0},
  {0x11, 1, "tps", "%", 1000, 0},
  {0x05, 1, "coolant", "C", 1000, 0},
  {0x0F, 1, "iat", "C", 1000, 0},
  {0x0B, 1, "map", "kPa", 1000, 0},
  {0x0D, 1, "speed", "km/h", 1000, 0},
  {0x42, 2, "ecu_voltage", "V", 1500, 0},
};

void appendFloat(String& packet, const char* key, float value, uint8_t decimals) {
  packet += ",\"";
  packet += key;
  packet += "\":";
  if (isnan(value)) {
    packet += "null";
  } else {
    packet += String(value, static_cast<unsigned int>(decimals));
  }
}

void appendHexByte(String& packet, uint8_t value) {
  static const char* HEX_DIGITS = "0123456789ABCDEF";
  packet += HEX_DIGITS[(value >> 4) & 0x0F];
  packet += HEX_DIGITS[value & 0x0F];
}

void appendHexWord(String& packet, uint16_t value) {
  static const char* HEX_DIGITS = "0123456789ABCDEF";
  packet += "\"0x";
  packet += HEX_DIGITS[(value >> 12) & 0x0F];
  packet += HEX_DIGITS[(value >> 8) & 0x0F];
  packet += HEX_DIGITS[(value >> 4) & 0x0F];
  packet += HEX_DIGITS[value & 0x0F];
  packet += "\"";
}

void appendFrameDataHex(String& packet, const uint8_t* data, uint8_t dlc) {
  for (uint8_t i = 0; i < dlc; i++) {
    if (i > 0) packet += ' ';
    appendHexByte(packet, data[i]);
  }
}

String sanitizeCaptureToken(String value, const char* fallback) {
  value.trim();
  if (value.length() == 0) value = fallback;

  String out;
  out.reserve(value.length());
  for (size_t i = 0; i < value.length() && out.length() < 48; i++) {
    char c = value[i];
    bool ok = (c >= 'a' && c <= 'z') ||
              (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') ||
              c == '_' || c == '-' || c == '.';
    out += ok ? c : '_';
  }
  if (out.length() == 0) out = fallback;
  return out;
}

uint32_t captureBytesUsed() {
  return captureFileBytes + captureBuffer.length();
}

uint32_t availableCaptureLimitBytes() {
  if (!fsReady) return 0;

  uint32_t total = LittleFS.totalBytes();
  uint32_t used = LittleFS.usedBytes();
  if (total <= used + CAPTURE_RESERVED_FS_BYTES) return 0;

  uint32_t freeForCapture = total - used - CAPTURE_RESERVED_FS_BYTES;
  if (captureActive) freeForCapture += captureBytesUsed();

  // Keep captures short and phone-downloadable. The analyzer is designed for
  // several focused clips rather than one huge ride log.
  const uint32_t hardCap = 3UL * 1024UL * 1024UL;
  return freeForCapture < hardCap ? freeForCapture : hardCap;
}

bool flushCaptureBuffer() {
  if (!captureActive || !captureFile) return false;
  if (captureBuffer.length() == 0) return true;

  size_t written = captureFile.print(captureBuffer);
  captureFileBytes += written;
  captureBuffer = "";
  captureLastFlushMs = millis();
  captureFile.flush();
  return written > 0;
}

void closeCaptureFile() {
  if (!captureActive && !captureFile) return;
  flushCaptureBuffer();
  if (captureFile) captureFile.close();
  captureActive = false;
}

void appendCaptureLine(const String& line) {
  if (!captureActive || !captureFile) return;

  if (captureMaxBytes > 0 && captureBytesUsed() + line.length() + 1 > captureMaxBytes) {
    captureDroppedRows++;
    closeCaptureFile();
    Serial.println("CAPTURE_STOP reason=file_limit");
    return;
  }

  captureBuffer += line;
  captureBuffer += '\n';
  if (captureBuffer.length() >= CAPTURE_FLUSH_BYTES ||
      millis() - captureLastFlushMs >= CAPTURE_FLUSH_INTERVAL_MS) {
    flushCaptureBuffer();
  }
}

bool startCapture(const String& requestedStage) {
  if (!fsReady) return false;
  closeCaptureFile();
  if (LittleFS.exists(CAPTURE_FILE_PATH)) LittleFS.remove(CAPTURE_FILE_PATH);

  captureStage = sanitizeCaptureToken(requestedStage, "baseline");
  captureRows = 0;
  captureMarks = 0;
  captureDroppedRows = 0;
  captureFileBytes = 0;
  captureBuffer = "";
  captureBuffer.reserve(CAPTURE_FLUSH_BYTES + 512);
  captureStartedMs = millis();
  captureLastFlushMs = captureStartedMs;
  captureStartRxFrames = rxFrames;
  captureMaxBytes = availableCaptureLimitBytes();
  if (captureMaxBytes < 64UL * 1024UL) {
    captureMaxBytes = 0;
    return false;
  }

  captureFile = LittleFS.open(CAPTURE_FILE_PATH, "w");
  if (!captureFile) {
    captureMaxBytes = 0;
    return false;
  }

  captureActive = true;
  appendCaptureLine("type,ms,stage,id_hex,extended,dlc,data_hex,label");

  String marker = "M,";
  marker += String(millis());
  marker += ",";
  marker += captureStage;
  marker += ",,,,,capture_started";
  appendCaptureLine(marker);
  captureMarks++;

  Serial.printf("CAPTURE_START path=%s stage=%s max_bytes=%lu\n",
                CAPTURE_FILE_PATH,
                captureStage.c_str(),
                static_cast<unsigned long>(captureMaxBytes));
  return true;
}

void markCapture(String requestedStage, String requestedLabel) {
  if (!captureActive || !captureFile) return;

  String group = sanitizeCaptureToken(requestedStage, "stage");
  String label = sanitizeCaptureToken(requestedLabel, group.c_str());
  captureStage = label;

  String line = "M,";
  line += String(millis());
  line += ",";
  line += captureStage;
  line += ",,,,,";
  line += group;
  appendCaptureLine(line);
  captureMarks++;
  Serial.printf("CAPTURE_MARK stage=%s group=%s\n", captureStage.c_str(), group.c_str());
}

void captureCanFrame(const CanFrame& frame) {
  if (!captureActive || !captureFile) return;

  String line;
  line.reserve(72);
  line += "F,";
  line += String(millis());
  line += ",";
  line += captureStage;
  line += ",0x";
  line += String(frame.id, HEX);
  line += ",";
  line += frame.extended ? "1" : "0";
  line += ",";
  line += String(frame.dlc);
  line += ",";
  appendFrameDataHex(line, frame.data, frame.dlc);
  line += ",";
  appendCaptureLine(line);
  captureRows++;
}

void maintainCapture() {
  if (!captureActive) return;
  if (millis() - captureLastFlushMs >= CAPTURE_FLUSH_INTERVAL_MS) {
    flushCaptureBuffer();
  }
}

String buildCaptureStatusPacket() {
  uint32_t now = millis();
  String packet;
  packet.reserve(720);
  packet += "{\"active\":";
  packet += captureActive ? "true" : "false";
  packet += ",\"path\":\"";
  packet += CAPTURE_FILE_PATH;
  packet += "\",\"stage\":\"";
  packet += captureStage;
  packet += "\",\"rows\":";
  packet += String(captureRows);
  packet += ",\"rx_frames\":";
  packet += String(rxFrames);
  packet += ",\"rx_frames_since_start\":";
  packet += String(rxFrames - captureStartRxFrames);
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"listen_only\":";
  packet += CAN_LISTEN_ONLY ? "true" : "false";
  packet += ",\"last_can_age_ms\":";
  if (lastCanFrameMs == 0) {
    packet += "null";
  } else {
    packet += String(now - lastCanFrameMs);
  }
  packet += ",\"mcp_status\":";
  packet += String(canReady ? can.status() : 0);
  packet += ",\"mcp_errors\":";
  packet += String(canReady ? can.errorFlags() : 0);
  packet += ",\"mcp_rx_overflows\":";
  packet += String(mcpRxOverflowEvents);
  packet += ",\"mcp_reinit_attempts\":";
  packet += String(mcpReinitAttempts);
  packet += ",\"dropped_corrupt_frames\":";
  packet += String(droppedCorruptFrames);
  packet += ",\"file_open\":";
  packet += captureFile ? "true" : "false";
  packet += ",\"buffer_bytes\":";
  packet += String(captureBuffer.length());
  packet += ",\"marks\":";
  packet += String(captureMarks);
  packet += ",\"dropped_rows\":";
  packet += String(captureDroppedRows);
  packet += ",\"bytes\":";
  packet += String(captureBytesUsed());
  packet += ",\"max_bytes\":";
  packet += String(captureMaxBytes);
  packet += ",\"elapsed_ms\":";
  if (captureStartedMs == 0) {
    packet += "0";
  } else {
    packet += String(now - captureStartedMs);
  }
  packet += ",\"fs_ready\":";
  packet += fsReady ? "true" : "false";
  packet += ",\"fs_total\":";
  if (fsReady) {
    packet += String(LittleFS.totalBytes());
  } else {
    packet += "0";
  }
  packet += ",\"fs_used\":";
  if (fsReady) {
    packet += String(LittleFS.usedBytes());
  } else {
    packet += "0";
  }
  packet += ",\"download_url\":\"/capture/download\"}";
  return packet;
}

void appendCsvField(String& line, const String& value) {
  line += ',';
  line += value;
}

void appendCsvField(String& line, const char* value) {
  line += ',';
  if (value) line += value;
}

void appendCsvEmptyFields(String& line, uint8_t count) {
  for (uint8_t i = 0; i < count; i++) {
    line += ',';
  }
}

void appendCsvFloatField(String& line, float value, uint8_t decimals) {
  line += ',';
  if (!isnan(value)) {
    line += String(value, static_cast<unsigned int>(decimals));
  }
}

String hexWordCsv(uint16_t value) {
  String out = "0x";
  if (value < 0x1000) out += "0";
  if (value < 0x0100) out += "0";
  if (value < 0x0010) out += "0";
  out += String(value, HEX);
  return out;
}

String hexByteCsv(uint8_t value) {
  String out = "0x";
  if (value < 0x10) out += "0";
  out += String(value, HEX);
  return out;
}

uint32_t correlateSessionMs() {
  return correlateStartedMs == 0 ? 0 : millis() - correlateStartedMs;
}

uint32_t correlateBytesUsed() {
  return correlateFileBytes + correlateBuffer.length();
}

uint32_t availableCorrelationLimitBytes() {
  if (!fsReady) return 0;

  uint32_t total = LittleFS.totalBytes();
  uint32_t used = LittleFS.usedBytes();
  if (total <= used + CORRELATE_RESERVED_FS_BYTES) return 0;

  uint32_t freeForCorrelation = total - used - CORRELATE_RESERVED_FS_BYTES;
  if (correlateActive) freeForCorrelation += correlateBytesUsed();

  const uint32_t hardCap = 3UL * 1024UL * 1024UL;
  return freeForCorrelation < hardCap ? freeForCorrelation : hardCap;
}

bool flushCorrelationBuffer() {
  if (!correlateActive || !correlateFile) return false;
  if (correlateBuffer.length() == 0) return true;

  size_t written = correlateFile.print(correlateBuffer);
  correlateFileBytes += written;
  correlateBuffer = "";
  correlateLastFlushMs = millis();
  correlateFile.flush();
  return written > 0;
}

void closeCorrelationFile() {
  bool wasActive = correlateActive;
  if (!correlateActive && !correlateFile) return;

  flushCorrelationBuffer();
  if (correlateFile) correlateFile.close();
  correlateActive = false;

  if (wasActive && canReady) {
    bool restored = can.configure(CAN_LISTEN_ONLY);
    canReady = restored;
    Serial.printf("CORRELATE_STOP rows=%lu frames=%lu obd=%lu ok=%lu fail=%lu restored_listen_only=%u\n",
                  static_cast<unsigned long>(correlateRows),
                  static_cast<unsigned long>(correlateFrameRows),
                  static_cast<unsigned long>(correlateObdRows),
                  static_cast<unsigned long>(correlateObdOk),
                  static_cast<unsigned long>(correlateObdFail),
                  restored ? 1 : 0);
  }
}

void appendCorrelationLine(const String& line) {
  if (!correlateActive || !correlateFile) return;

  if (correlateMaxBytes > 0 && correlateBytesUsed() + line.length() + 1 > correlateMaxBytes) {
    correlateDroppedRows++;
    Serial.println("CORRELATE_STOP reason=file_limit");
    closeCorrelationFile();
    return;
  }

  correlateBuffer += line;
  correlateBuffer += '\n';
  correlateRows++;
  if (correlateBuffer.length() >= CORRELATE_FLUSH_BYTES ||
      millis() - correlateLastFlushMs >= CORRELATE_FLUSH_INTERVAL_MS) {
    flushCorrelationBuffer();
  }
}

void appendCorrelationCounters(String& line) {
  appendCsvField(line, String(rxFrames));
  appendCsvField(line, String(txRequests));
  appendCsvField(line, String(rxResponses));
  appendCsvField(line, String(pidTimeouts));
  appendCsvField(line, String(mcpRxOverflowEvents));
}

void appendCorrelationDecodedFields(String& line) {
  appendCsvFloatField(line, telemetry.rpm, 1);
  if (hasPassiveRpm) {
    appendCsvField(line, hexWordCsv(lastPassiveRpmRaw));
    String id = "0x";
    id += String(lastPassiveRpmFrameId, HEX);
    appendCsvField(line, id);
  } else {
    appendCsvField(line, "");
    appendCsvField(line, "");
  }
  if (hasPassiveTps) {
    appendCsvField(line, String(lastPassiveTpsRaw));
    appendCsvFloatField(line, lastPassiveTpsGrip, 1);
    appendCsvFloatField(line, lastPassiveTpsAbs, 1);
  } else {
    appendCsvField(line, "");
    appendCsvField(line, "");
    appendCsvField(line, "");
  }
  appendCsvField(line, estimatedGear());
  if (hasPassiveGear) {
    appendCsvField(line, String(lastPassiveGearRaw));
  } else {
    appendCsvField(line, "");
  }
  appendCsvFloatField(line, telemetry.coolant, 1);
  appendCsvFloatField(line, telemetry.iat, 1);
  appendCsvFloatField(line, telemetry.map, 1);
  appendCsvFloatField(line, telemetry.speed, 1);
  appendCsvFloatField(line, telemetry.vbatt, 2);
}

void appendCorrelationMarker(const char* label) {
  if (!correlateActive || !correlateFile) return;

  String line = "M";
  appendCsvField(line, String(millis()));
  appendCsvField(line, String(correlateSessionMs()));
  appendCsvField(line, correlateStage);
  appendCsvEmptyFields(line, 24);
  appendCorrelationCounters(line);
  appendCsvField(line, label);
  appendCorrelationLine(line);
  correlateMarks++;
}

void appendCorrelationSummary(const char* label) {
  if (!correlateActive || !correlateFile) return;

  String line = "S";
  appendCsvField(line, String(millis()));
  appendCsvField(line, String(correlateSessionMs()));
  appendCsvField(line, correlateStage);
  appendCsvEmptyFields(line, 11);
  appendCorrelationDecodedFields(line);
  appendCorrelationCounters(line);
  appendCsvField(line, label);
  appendCorrelationLine(line);
  correlateSummaryRows++;
}

void correlateCanFrame(const CanFrame& frame) {
  if (!correlateActive || !correlateFile) return;

  String dataHex;
  dataHex.reserve(24);
  appendFrameDataHex(dataHex, frame.data, frame.dlc);

  String idHex = "0x";
  idHex += String(frame.id, HEX);

  String line = "F";
  line.reserve(120);
  appendCsvField(line, String(millis()));
  appendCsvField(line, String(correlateSessionMs()));
  appendCsvField(line, correlateStage);
  appendCsvField(line, idHex);
  appendCsvField(line, frame.extended ? "1" : "0");
  appendCsvField(line, String(frame.dlc));
  appendCsvField(line, dataHex);
  appendCsvEmptyFields(line, 20);
  appendCorrelationCounters(line);
  appendCsvField(line, "");
  appendCorrelationLine(line);
  correlateFrameRows++;
}

void appendCorrelationObdRow(const CorrelatePid& spec,
                             bool ok,
                             float value,
                             uint16_t raw,
                             const String& bytes) {
  String line = "O";
  line.reserve(220);
  appendCsvField(line, String(millis()));
  appendCsvField(line, String(correlateSessionMs()));
  appendCsvField(line, correlateStage);
  appendCsvEmptyFields(line, 4);
  appendCsvField(line, hexByteCsv(spec.pid));
  appendCsvField(line, spec.name);
  appendCsvField(line, ok ? "1" : "0");
  appendCsvFloatField(line, ok ? value : NAN, 2);
  appendCsvField(line, ok ? spec.unit : "");
  appendCsvField(line, ok ? hexWordCsv(raw) : "");
  appendCsvField(line, bytes);
  appendCorrelationDecodedFields(line);
  appendCorrelationCounters(line);
  appendCsvField(line, "");
  appendCorrelationLine(line);
  correlateObdRows++;
  if (ok) {
    correlateObdOk++;
  } else {
    correlateObdFail++;
  }
}

void appendCorrelationOverflow(uint8_t flags) {
  if (!correlateActive || !correlateFile) return;
  uint32_t now = millis();
  if (now - correlateLastOverflowLogMs < 250) return;
  correlateLastOverflowLogMs = now;

  String label = "mcp_rx_overflow_";
  label += hexByteCsv(flags);

  String line = "E";
  appendCsvField(line, String(now));
  appendCsvField(line, String(correlateSessionMs()));
  appendCsvField(line, correlateStage);
  appendCsvEmptyFields(line, 24);
  appendCorrelationCounters(line);
  appendCsvField(line, label);
  appendCorrelationLine(line);
}

String buildCorrelationStatusPacket() {
  uint32_t now = millis();
  String packet;
  packet.reserve(900);
  packet += "{\"active\":";
  packet += correlateActive ? "true" : "false";
  packet += ",\"path\":\"";
  packet += CORRELATE_FILE_PATH;
  packet += "\",\"stage\":\"";
  packet += correlateStage;
  packet += "\",\"rows\":";
  packet += String(correlateRows);
  packet += ",\"frame_rows\":";
  packet += String(correlateFrameRows);
  packet += ",\"obd_rows\":";
  packet += String(correlateObdRows);
  packet += ",\"obd_ok\":";
  packet += String(correlateObdOk);
  packet += ",\"obd_fail\":";
  packet += String(correlateObdFail);
  packet += ",\"summary_rows\":";
  packet += String(correlateSummaryRows);
  packet += ",\"marks\":";
  packet += String(correlateMarks);
  packet += ",\"dropped_rows\":";
  packet += String(correlateDroppedRows);
  packet += ",\"rx_frames\":";
  packet += String(rxFrames);
  packet += ",\"rx_frames_since_start\":";
  packet += String(rxFrames - correlateStartRxFrames);
  packet += ",\"tx_requests_delta\":";
  packet += String(txRequests - correlateStartTxRequests);
  packet += ",\"rx_responses_delta\":";
  packet += String(rxResponses - correlateStartRxResponses);
  packet += ",\"pid_timeouts_delta\":";
  packet += String(pidTimeouts - correlateStartPidTimeouts);
  packet += ",\"overflow_delta\":";
  packet += String(mcpRxOverflowEvents - correlateStartMcpRxOverflows);
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"last_can_age_ms\":";
  if (lastCanFrameMs == 0) {
    packet += "null";
  } else {
    packet += String(now - lastCanFrameMs);
  }
  packet += ",\"mcp_status\":";
  packet += String(canReady ? can.status() : 0);
  packet += ",\"mcp_errors\":";
  packet += String(canReady ? can.errorFlags() : 0);
  packet += ",\"mcp_rx_overflows\":";
  packet += String(mcpRxOverflowEvents);
  packet += ",\"mcp_reinit_attempts\":";
  packet += String(mcpReinitAttempts);
  packet += ",\"dropped_corrupt_frames\":";
  packet += String(droppedCorruptFrames);
  packet += ",\"file_open\":";
  packet += correlateFile ? "true" : "false";
  packet += ",\"buffer_bytes\":";
  packet += String(correlateBuffer.length());
  packet += ",\"bytes\":";
  packet += String(correlateBytesUsed());
  packet += ",\"max_bytes\":";
  packet += String(correlateMaxBytes);
  packet += ",\"elapsed_ms\":";
  packet += String(correlateActive ? correlateSessionMs() : 0);
  packet += ",\"max_session_ms\":";
  packet += String(CORRELATE_MAX_SESSION_MS);
  packet += ",\"download_url\":\"/correlate/download\"}";
  return packet;
}

void serviceMcpRxOverflows() {
  if (!canReady) return;
  uint8_t overflowFlags = can.rxOverflowFlags();
  if (!overflowFlags) return;

  if (overflowFlags & 0x40) mcpRxOverflowEvents++;
  if (overflowFlags & 0x80) mcpRxOverflowEvents++;
  lastMcpRxOverflowMs = millis();
  can.clearRxOverflowFlags();
  appendCorrelationOverflow(overflowFlags);
}

void rememberCanFrame(const CanFrame& frame) {
  uint32_t now = millis();
  lastCanFrameMs = now;

  RecentCanFrame& recent = recentCanFrames[recentCanWriteIndex];
  recent.ms = now;
  recent.id = frame.id;
  recent.extended = frame.extended;
  recent.dlc = frame.dlc;
  for (uint8_t i = 0; i < 8; i++) {
    recent.data[i] = i < frame.dlc ? frame.data[i] : 0;
  }

  recentCanWriteIndex = (recentCanWriteIndex + 1) % CAN_RECENT_COUNT;
  if (recentCanStored < CAN_RECENT_COUNT) recentCanStored++;

  size_t statIndex = CAN_ID_STATS_COUNT;
  size_t firstFreeIndex = CAN_ID_STATS_COUNT;
  size_t oldestIndex = 0;
  uint32_t oldestMs = UINT32_MAX;

  for (size_t i = 0; i < CAN_ID_STATS_COUNT; i++) {
    CanIdStat& stat = canIdStats[i];
    if (stat.used && stat.id == frame.id && stat.extended == frame.extended) {
      statIndex = i;
      break;
    }
    if (!stat.used && firstFreeIndex == CAN_ID_STATS_COUNT) {
      firstFreeIndex = i;
    }
    if (stat.used && stat.lastMs < oldestMs) {
      oldestMs = stat.lastMs;
      oldestIndex = i;
    }
  }

  if (statIndex == CAN_ID_STATS_COUNT) {
    statIndex = firstFreeIndex != CAN_ID_STATS_COUNT ? firstFreeIndex : oldestIndex;
    canIdStats[statIndex].count = 0;
  }

  CanIdStat& stat = canIdStats[statIndex];
  stat.used = true;
  stat.id = frame.id;
  stat.extended = frame.extended;
  stat.count++;
  stat.lastMs = now;
  stat.dlc = frame.dlc;
  for (uint8_t i = 0; i < 8; i++) {
    stat.data[i] = i < frame.dlc ? frame.data[i] : 0;
  }
}

bool isImportantFilteredStandardId(uint32_t id) {
  return id == 0x301 || id == 0x302 || id == 0x303 || id == 0x30C || id == 0x447;
}

bool shouldDropCanFrame(const CanFrame& frame) {
  if (frame.dlc > 8) return true;

  if (MCP_FILTER_IMPORTANT_IDS_ONLY) {
    if (DROP_EXTENDED_FRAMES_IN_FILTERED_MODE && frame.extended) return true;
    if (!frame.extended && !isImportantFilteredStandardId(frame.id)) return true;
  }

  bool allBytesFf = frame.dlc > 0;
  for (uint8_t i = 0; i < frame.dlc; i++) {
    if (frame.data[i] != 0xFF) {
      allBytesFf = false;
      break;
    }
  }
  if (frame.extended && frame.id == 0x1FFFFFFF && allBytesFf) return true;
  if (!frame.extended && frame.id == 0x30C && frame.dlc == 2 &&
      frame.data[0] == 0xFF && frame.data[1] == 0xFF) {
    return true;
  }

  return false;
}

bool ingestCanFrame(const CanFrame& frame) {
  if (shouldDropCanFrame(frame)) {
    droppedCorruptFrames++;
    return false;
  }

  rememberCanFrame(frame);
  captureCanFrame(frame);
  correlateCanFrame(frame);
  return applyPassiveCanFrame(frame);
}

static const char* TRIP_DISTANCE_PREF_KEYS[TRIP_COUNT] = {"t1_dist_m", "t2_dist_m"};
static const char* TRIP_FUEL_PREF_KEYS[TRIP_COUNT] = {"t1_fuel_ml", "t2_fuel_ml"};
static const char* TRIP_SECONDS_PREF_KEYS[TRIP_COUNT] = {"t1_sec", "t2_sec"};

void maintainCanHealth() {
  if (!CAN_LISTEN_ONLY || WIFI_MOCK_TELEMETRY_ENABLED) return;

  uint32_t now = millis();
  if (now - lastMcpReinitMs < CAN_REINIT_COOLDOWN_MS) return;

  if (!canReady) {
    lastMcpReinitMs = now;
    mcpReinitAttempts++;
    bool restored = can.begin() && can.configure(CAN_LISTEN_ONLY);
    canReady = restored;
    Serial.printf("MCP2515 offline reinit: ok=%u attempts=%lu dropped_bad_frames=%lu\n",
                  restored ? 1 : 0,
                  static_cast<unsigned long>(mcpReinitAttempts),
                  static_cast<unsigned long>(droppedCorruptFrames));
    return;
  }

  bool stale = false;
  if (lastCanFrameMs == 0) {
    stale = now >= CAN_STALE_REINIT_MS;
  } else {
    stale = now - lastCanFrameMs >= CAN_STALE_REINIT_MS;
  }
  if (!stale) return;

  lastMcpReinitMs = now;
  mcpReinitAttempts++;
  bool restored = can.configure(CAN_LISTEN_ONLY);
  canReady = restored;
  if (restored) {
    lastMcpRxOverflowMs = 0;
  }
  Serial.printf("MCP2515 stale receive reinit: ok=%u attempts=%lu last_can_age_ms=%lu dropped_bad_frames=%lu\n",
                restored ? 1 : 0,
                static_cast<unsigned long>(mcpReinitAttempts),
                static_cast<unsigned long>(lastCanFrameMs == 0 ? now : now - lastCanFrameMs),
                static_cast<unsigned long>(droppedCorruptFrames));
}

float odometerKm() {
  return (static_cast<float>(odometerMeters) + odometerFractionMeters) / 1000.0f;
}

float distanceSpeedKph(float displayedSpeedKph) {
  return hasPassiveSpeed
             ? displayedSpeedKph * PASSIVE_DISTANCE_CALIBRATION
             : displayedSpeedKph;
}

uint32_t odometerUnsavedMeters() {
  return odometerMeters >= odometerLastSavedMeters ? odometerMeters - odometerLastSavedMeters : 0;
}

bool saveOdometer(bool force) {
  if (!odometerPrefsReady) return false;
  uint32_t unsavedMeters = odometerUnsavedMeters();
  if (!force && unsavedMeters == 0) return true;

  size_t written = odometerPrefs.putUInt(ODOMETER_PREF_METERS_KEY, odometerMeters);
  if (written == sizeof(uint32_t)) {
    odometerLastSavedMeters = odometerMeters;
    odometerLastSaveMs = millis();
    odometerSaveCount++;
    return true;
  }
  return false;
}

void maybeSaveOdometer(uint32_t now) {
  uint32_t unsavedMeters = odometerUnsavedMeters();
  if (unsavedMeters == 0) return;
  if (unsavedMeters >= ODOMETER_SAVE_DISTANCE_METERS ||
      now - odometerLastSaveMs >= ODOMETER_SAVE_INTERVAL_MS) {
    saveOdometer(false);
  }
}

void maintainOdometer() {
  uint32_t now = millis();
  bool speedFresh = hasPassiveSpeed &&
                    !isnan(telemetry.speed) &&
                    now - lastPassiveSpeedMs <= ODOMETER_SPEED_MAX_AGE_MS;
  float speedKph =
      speedFresh
          ? distanceSpeedKph(constrain(telemetry.speed, 0.0f, 299.0f))
          : 0.0f;
  bool moving = speedFresh && speedKph >= ODOMETER_MIN_SPEED_KPH;

  if (!moving) {
    if (odometerWasMoving) {
      saveOdometer(true);
    }
    odometerWasMoving = false;
    odometerLastUpdateMs = now;
    return;
  }

  if (odometerLastUpdateMs == 0) {
    odometerLastUpdateMs = now;
    odometerWasMoving = true;
    return;
  }

  uint32_t dtMs = now - odometerLastUpdateMs;
  odometerLastUpdateMs = now;
  odometerWasMoving = true;

  if (dtMs == 0 || dtMs > ODOMETER_MAX_INTEGRATION_GAP_MS) {
    return;
  }

  odometerFractionMeters += speedKph * static_cast<float>(dtMs) / 3600.0f;
  if (odometerFractionMeters >= 1.0f) {
    uint32_t wholeMeters = static_cast<uint32_t>(odometerFractionMeters);
    odometerMeters += wholeMeters;
    odometerFractionMeters -= static_cast<float>(wholeMeters);
  }

  maybeSaveOdometer(now);
}

float tripDistanceKm(const TripState& trip) {
  return (static_cast<float>(trip.distanceMeters) + trip.distanceFractionMeters) / 1000.0f;
}

float tripFuelLiters(const TripState& trip) {
  return (static_cast<float>(trip.fuelMilliLiters) + trip.fuelFractionMilliLiters) / 1000.0f;
}

float tripKmpl(const TripState& trip) {
  float fuelLiters = tripFuelLiters(trip);
  if (fuelLiters <= 0.0001f) return 0.0f;
  return tripDistanceKm(trip) / fuelLiters;
}

bool tripDirty(uint8_t index) {
  if (index >= TRIP_COUNT) return false;
  const TripState& trip = trips[index];
  return trip.distanceMeters != trip.savedDistanceMeters ||
         trip.fuelMilliLiters != trip.savedFuelMilliLiters ||
         trip.seconds != trip.savedSeconds;
}

uint32_t tripUnsavedMeters(uint8_t index) {
  if (index >= TRIP_COUNT) return 0;
  const TripState& trip = trips[index];
  return trip.distanceMeters >= trip.savedDistanceMeters
             ? trip.distanceMeters - trip.savedDistanceMeters
             : 0;
}

bool saveTrip(uint8_t index, bool force) {
  if (index >= TRIP_COUNT) return false;
  if (!odometerPrefsReady) return false;
  if (!force && !tripDirty(index)) return true;

  TripState& trip = trips[index];
  size_t distanceWritten = odometerPrefs.putUInt(TRIP_DISTANCE_PREF_KEYS[index], trip.distanceMeters);
  size_t fuelWritten = odometerPrefs.putUInt(TRIP_FUEL_PREF_KEYS[index], trip.fuelMilliLiters);
  size_t secondsWritten = odometerPrefs.putUInt(TRIP_SECONDS_PREF_KEYS[index], trip.seconds);
  if (distanceWritten == sizeof(uint32_t) &&
      fuelWritten == sizeof(uint32_t) &&
      secondsWritten == sizeof(uint32_t)) {
    trip.savedDistanceMeters = trip.distanceMeters;
    trip.savedFuelMilliLiters = trip.fuelMilliLiters;
    trip.savedSeconds = trip.seconds;
    trip.saveCount++;
    tripLastSaveMs = millis();
    return true;
  }
  return false;
}

bool saveAllTrips(bool force) {
  bool ok = true;
  for (uint8_t i = 0; i < TRIP_COUNT; i++) {
    ok = saveTrip(i, force) && ok;
  }
  return ok;
}

void maybeSaveTrips(uint32_t now) {
  bool anyDirty = false;
  bool distanceThresholdReached = false;
  for (uint8_t i = 0; i < TRIP_COUNT; i++) {
    if (!tripDirty(i)) continue;
    anyDirty = true;
    if (tripUnsavedMeters(i) >= TRIP_SAVE_DISTANCE_METERS) {
      distanceThresholdReached = true;
    }
  }
  if (!anyDirty) return;

  if (distanceThresholdReached || now - tripLastSaveMs >= TRIP_SAVE_INTERVAL_MS) {
    saveAllTrips(false);
  }
}

void resetTrip(uint8_t index) {
  if (index >= TRIP_COUNT) return;
  TripState& trip = trips[index];
  trip.distanceMeters = 0;
  trip.fuelMilliLiters = 0;
  trip.seconds = 0;
  trip.distanceFractionMeters = 0.0f;
  trip.fuelFractionMilliLiters = 0.0f;
}

bool tripRpmFresh(uint32_t now) {
  if (WIFI_MOCK_TELEMETRY_ENABLED) return !isnan(telemetry.rpm);
  return hasPassiveRpm && !isnan(telemetry.rpm) && now - lastPassiveRpmMs <= TRIP_RPM_MAX_AGE_MS;
}

bool tripSpeedFresh(uint32_t now) {
  if (WIFI_MOCK_TELEMETRY_ENABLED) return !isnan(telemetry.speed);
  return hasPassiveSpeed && !isnan(telemetry.speed) && now - lastPassiveSpeedMs <= TRIP_SPEED_MAX_AGE_MS;
}

bool tripSensorFresh(uint32_t now) {
  if (WIFI_MOCK_TELEMETRY_ENABLED) {
    return !isnan(telemetry.tps) && !isnan(telemetry.iat) && !isnan(telemetry.map);
  }
  return hasPassiveTps && hasPassiveIat && hasPassiveMap &&
         !isnan(telemetry.tps) && !isnan(telemetry.iat) && !isnan(telemetry.map) &&
         now - lastPassiveTpsMs <= TRIP_SENSOR_MAX_AGE_MS &&
         now - lastPassiveIatMs <= TRIP_SENSOR_MAX_AGE_MS &&
         now - lastPassiveMapMs <= TRIP_SENSOR_MAX_AGE_MS;
}

float estimateFuelRateLph(uint32_t now) {
  if (!tripRpmFresh(now) || !tripSensorFresh(now)) return 0.0f;

  float rpm = constrain(telemetry.rpm, 0.0f, 14000.0f);
  if (rpm <= TRIP_ENGINE_RUNNING_RPM) return 0.0f;

  float mapKpa = constrain(telemetry.map, 5.0f, 120.0f);
  float iatKelvin = telemetry.iat + 273.15f;
  if (iatKelvin < 230.0f) iatKelvin = 230.0f;
  float tpsPct = constrain(telemetry.tps, 0.0f, 100.0f);

  float mapPascal = mapKpa * 1000.0f;
  float airDensity = mapPascal / (TRIP_GAS_CONSTANT_R * iatKelvin);
  float volumeFlowPerSec = (rpm / 60.0f) / 2.0f * TRIP_DISPLACEMENT_M3;
  float volumetricEfficiency = TRIP_VE_BASE + (tpsPct / 100.0f) * TRIP_VE_TPS_SCALE;
  float airMassFlowGps = volumeFlowPerSec * airDensity * volumetricEfficiency * 1000.0f;
  float fuelMassFlowGps = airMassFlowGps / TRIP_STOICH_AFR;
  return (fuelMassFlowGps * 3600.0f) / TRIP_FUEL_DENSITY_G_L;
}

void accumulateTripTick(uint32_t now) {
  bool engineRunning = tripRpmFresh(now) &&
                       !isnan(telemetry.rpm) &&
                       telemetry.rpm > TRIP_ENGINE_RUNNING_RPM;
  float speedKph = 0.0f;
  if (tripSpeedFresh(now)) {
    speedKph = distanceSpeedKph(
        constrain(telemetry.speed, 0.0f, 299.0f));
    if (speedKph < ODOMETER_MIN_SPEED_KPH) speedKph = 0.0f;
  }

  float distanceMetersThisSecond = speedKph / 3.6f;
  float fuelMilliLitersThisSecond = estimateFuelRateLph(now) / 3.6f;

  for (uint8_t i = 0; i < TRIP_COUNT; i++) {
    TripState& trip = trips[i];
    if (engineRunning && trip.seconds < UINT32_MAX) {
      trip.seconds++;
    }

    trip.distanceFractionMeters += distanceMetersThisSecond;
    if (trip.distanceFractionMeters >= 1.0f) {
      uint32_t wholeMeters = static_cast<uint32_t>(trip.distanceFractionMeters);
      trip.distanceMeters += wholeMeters;
      trip.distanceFractionMeters -= static_cast<float>(wholeMeters);
    }

    trip.fuelFractionMilliLiters += fuelMilliLitersThisSecond;
    if (trip.fuelFractionMilliLiters >= 1.0f) {
      uint32_t wholeMilliLiters = static_cast<uint32_t>(trip.fuelFractionMilliLiters);
      trip.fuelMilliLiters += wholeMilliLiters;
      trip.fuelFractionMilliLiters -= static_cast<float>(wholeMilliLiters);
    }
  }
}

void maintainTripComputer() {
  uint32_t now = millis();
  bool engineRunning = tripRpmFresh(now) &&
                       !isnan(telemetry.rpm) &&
                       telemetry.rpm > TRIP_ENGINE_RUNNING_RPM;

  if (tripLastTickMs == 0) {
    tripLastTickMs = now;
    tripLastSaveMs = now;
    tripWasActive = engineRunning;
    return;
  }

  uint32_t elapsedMs = now - tripLastTickMs;
  if (elapsedMs >= TRIP_TICK_MS) {
    uint32_t ticks = elapsedMs / TRIP_TICK_MS;
    bool capped = false;
    if (ticks > 2) {
      ticks = 1;
      capped = true;
    }
    for (uint32_t tick = 0; tick < ticks; tick++) {
      accumulateTripTick(now);
    }
    tripLastTickMs = capped ? now : tripLastTickMs + ticks * TRIP_TICK_MS;
  }

  if (!engineRunning && tripWasActive) {
    saveAllTrips(true);
  }
  tripWasActive = engineRunning;
  maybeSaveTrips(now);
}

String estimatedGear() {
  if (hasPassiveGear) {
    switch (lastPassiveGearRaw) {
      case 0:
        return "N";
      case 1:
        return "1";
      case 2:
        return "2";
      case 3:
        return "3";
      case 4:
        return "4";
      case 5:
        return "5";
      case 6:
        return "6";
    }
  }

  if (isnan(telemetry.speed) || telemetry.speed < 3) return "N";
  if (telemetry.speed < 23) return "1";
  if (telemetry.speed < 43) return "2";
  if (telemetry.speed < 68) return "3";
  if (telemetry.speed < 94) return "4";
  if (telemetry.speed < 125) return "5";
  return "6";
}

float passiveTpsGripPct(uint8_t raw) {
  return static_cast<float>(raw) * 100.0f / 255.0f;
}

float passiveTpsAbsPct(uint8_t raw) {
  float value = PASSIVE_TPS_IDLE_OBD_PCT + static_cast<float>(raw) * PASSIVE_TPS_ABS_SCALE;
  return constrain(value, PASSIVE_TPS_IDLE_OBD_PCT, 100.0f);
}

float passiveCoolantC(int16_t raw) {
  return PASSIVE_COOLANT_SCALE * static_cast<float>(raw) + PASSIVE_COOLANT_OFFSET;
}

float passiveIatC(uint8_t raw) {
  return PASSIVE_IAT_SCALE * static_cast<float>(raw) + PASSIVE_IAT_OFFSET;
}

float passiveMapKpa(uint8_t raw) {
  return static_cast<float>(raw) + PASSIVE_MAP_OFFSET_KPA;
}

float obdAbsTpsToGripPct(float absPct) {
  float value = (absPct - PASSIVE_TPS_IDLE_OBD_PCT) * 100.0f /
                (100.0f - PASSIVE_TPS_IDLE_OBD_PCT);
  return constrain(value, 0.0f, 100.0f);
}

uint8_t linkQuality() {
  if (WIFI_MOCK_TELEMETRY_ENABLED) return 100;
  if (CAN_LISTEN_ONLY) {
    if (!canReady || lastCanFrameMs == 0) return 0;
    uint32_t age = millis() - lastCanFrameMs;
    if (age < 200) return 100;
    if (age < 500) return 75;
    if (age < 1000) return 35;
    return 0;
  }
  if (!canReady || lastGoodResponseMs == 0) return 0;
  uint32_t age = millis() - lastGoodResponseMs;
  if (age < 500) return 100;
  if (age < 1000) return 75;
  if (age < 2000) return 35;
  return 0;
}

float triangleSweep(float t, float period) {
  float phase = fmodf(t, period) / period;
  float linear = phase < 0.5f ? phase * 2.0f : (1.0f - phase) * 2.0f;
  float edgeBoost = 0.1f;
  return constrain(linear + edgeBoost * sinf(2.0f * PI * linear) / (2.0f * PI), 0.0f, 1.0f);
}

void updateMockTelemetry() {
  float t = millis() / 1000.0f;
  float sweep = triangleSweep(t, 5.4f);
  float throttle = sweep * 100.0f;
  float tempPhase = fmodf(t, 20.0f) < 10.0f ? 0.0f : 1.0f;
  float coolant = tempPhase < 0.5f ? 70.0f : 80.0f;

  telemetry.rpm = sweep * 10000.0f;
  telemetry.speed = sweep * 100.0f;
  telemetry.coolant = coolant;
  telemetry.iat = 31.0f + 2.2f * sinf(t * 0.12f);
  telemetry.map = constrain(29.0f + throttle * 0.58f + 5.0f * sinf(t * 1.6f), 20.0f, 104.0f);
  telemetry.tps = throttle;
  telemetry.tpsAbs = PASSIVE_TPS_IDLE_OBD_PCT +
                     throttle * (100.0f - PASSIVE_TPS_IDLE_OBD_PCT) / 100.0f;
  telemetry.vbatt = 14.12f + 0.08f * sinf(t * 0.9f);
}

void appendTripFields(String& packet, uint8_t slot) {
  if (slot < 1 || slot > TRIP_COUNT) return;
  uint8_t index = slot - 1;
  const TripState& trip = trips[index];
  char key[32];

  snprintf(key, sizeof(key), "trip%u_distance_km", slot);
  appendFloat(packet, key, tripDistanceKm(trip), 1);
  snprintf(key, sizeof(key), "trip%u_kmpl", slot);
  appendFloat(packet, key, tripKmpl(trip), 1);
  snprintf(key, sizeof(key), "trip%u_fuel_l", slot);
  appendFloat(packet, key, tripFuelLiters(trip), 3);

  snprintf(key, sizeof(key), "trip%u_seconds", slot);
  packet += ",\"";
  packet += key;
  packet += "\":";
  packet += String(trip.seconds);

  snprintf(key, sizeof(key), "trip%u_distance_m", slot);
  packet += ",\"";
  packet += key;
  packet += "\":";
  packet += String(trip.distanceMeters);

  snprintf(key, sizeof(key), "trip%u_persisted_distance_m", slot);
  packet += ",\"";
  packet += key;
  packet += "\":";
  packet += String(trip.savedDistanceMeters);

  snprintf(key, sizeof(key), "trip%u_unsaved_distance_m", slot);
  packet += ",\"";
  packet += key;
  packet += "\":";
  packet += String(tripUnsavedMeters(index));

  snprintf(key, sizeof(key), "trip%u_save_count", slot);
  packet += ",\"";
  packet += key;
  packet += "\":";
  packet += String(trip.saveCount);
}

void appendAllTripFields(String& packet) {
  for (uint8_t slot = 1; slot <= TRIP_COUNT; slot++) {
    appendTripFields(packet, slot);
  }
  packet += ",\"trip_count\":";
  packet += String(TRIP_COUNT);
  packet += ",\"trip_source\":\"speed-integrated-fuel-estimate\"";
  appendFloat(
      packet,
      "trip_distance_calibration",
      PASSIVE_DISTANCE_CALIBRATION,
      4);
  packet += ",\"trip_prefs_ready\":";
  packet += odometerPrefsReady ? "true" : "false";
}

String buildTelemetryPacket() {
  String packet;
  packet.reserve(1400);
  packet += "{\"seq\":";
  packet += String(++seqNo);
  packet += ",\"ms\":";
  packet += String(millis());

  appendFloat(packet, "rpm", telemetry.rpm, 1);
  appendFloat(packet, "speed_kph", telemetry.speed, 1);
  appendFloat(packet, "speed", telemetry.speed, 1);
  appendFloat(packet, "odometer_km", odometerKm(), 1);
  packet += ",\"odometer_m\":";
  packet += String(odometerMeters);
  packet += ",\"odometer_persisted_m\":";
  packet += String(odometerLastSavedMeters);
  packet += ",\"odometer_unsaved_m\":";
  packet += String(odometerUnsavedMeters());
  packet += ",\"odometer_source\":\"speed-integrated-0x30c\"";
  packet += ",\"odometer_prefs_ready\":";
  packet += odometerPrefsReady ? "true" : "false";
  packet += ",\"odometer_save_count\":";
  packet += String(odometerSaveCount);
  appendAllTripFields(packet);
  packet += ",\"speed_source\":\"";
  packet += hasPassiveSpeed ? "passive-can-0x30c" : "obd-or-mock";
  packet += "\"";
  packet += ",\"speed_raw\":";
  if (hasPassiveSpeed) {
    packet += String(lastPassiveSpeedRaw);
  } else {
    packet += "null";
  }
  packet += ",\"speed_age_ms\":";
  if (hasPassiveSpeed) {
    packet += String(millis() - lastPassiveSpeedMs);
  } else {
    packet += "null";
  }
  packet += ",\"gear\":\"";
  packet += estimatedGear();
  packet += "\"";
  packet += ",\"gear_raw\":";
  if (hasPassiveGear) {
    packet += String(lastPassiveGearRaw);
  } else {
    packet += "null";
  }
  packet += ",\"gear_source\":\"";
  packet += hasPassiveGear ? "passive-can" : "speed-estimate";
  packet += "\"";
  packet += ",\"gear_age_ms\":";
  if (hasPassiveGear) {
    packet += String(millis() - lastPassiveGearMs);
  } else {
    packet += "null";
  }
  appendFloat(packet, "coolant_c", telemetry.coolant, 1);
  appendFloat(packet, "coolant", telemetry.coolant, 1);
  appendFloat(packet, "engine_temp_c", telemetry.coolant, 1);
  appendFloat(packet, "iat_c", telemetry.iat, 1);
  appendFloat(packet, "iat", telemetry.iat, 1);
  appendFloat(packet, "map_kpa", telemetry.map, 1);
  appendFloat(packet, "map", telemetry.map, 1);
  appendFloat(packet, "tps_pct", telemetry.tps, 1);
  appendFloat(packet, "tps", telemetry.tps, 1);
  appendFloat(packet, "throttle_pct", telemetry.tps, 1);
  appendFloat(packet, "throttle", telemetry.tps, 1);
  appendFloat(packet, "tps_abs_pct", telemetry.tpsAbs, 1);
  appendFloat(packet, "tps_obd_equiv_pct", telemetry.tpsAbs, 1);
  packet += ",\"tps_raw\":";
  if (hasPassiveTps) {
    packet += String(lastPassiveTpsRaw);
  } else {
    packet += "null";
  }
  packet += ",\"tps_source\":\"";
  packet += hasPassiveTps ? "passive-can" : "obd-or-mock";
  packet += "\"";
  packet += ",\"coolant_source\":\"";
  packet += hasPassiveCoolant ? "passive-can-0x302" : "obd-or-mock";
  packet += "\"";
  packet += ",\"coolant_raw\":";
  if (hasPassiveCoolant) {
    packet += String(lastPassiveCoolantRaw);
  } else {
    packet += "null";
  }
  packet += ",\"iat_source\":\"";
  packet += hasPassiveIat ? "passive-can-0x302" : "obd-or-mock";
  packet += "\"";
  packet += ",\"iat_raw\":";
  if (hasPassiveIat) {
    packet += String(lastPassiveIatRaw);
  } else {
    packet += "null";
  }
  packet += ",\"map_source\":\"";
  packet += hasPassiveMap ? "passive-can-0x302" : "obd-or-mock";
  packet += "\"";
  packet += ",\"map_raw\":";
  if (hasPassiveMap) {
    packet += String(lastPassiveMapRaw);
  } else {
    packet += "null";
  }
  appendFloat(packet, "battery_v", telemetry.vbatt, 2);
  appendFloat(packet, "vbatt", telemetry.vbatt, 2);
  packet += ",\"battery_source\":\"";
  packet += hasPassiveBattery ? "passive-can-0x303-candidate" : "obd-or-mock";
  packet += "\"";
  packet += ",\"battery_raw\":";
  if (hasPassiveBattery) {
    packet += String(lastPassiveBatteryRaw);
  } else {
    packet += "null";
  }
  packet += ",\"battery_age_ms\":";
  if (hasPassiveBattery) {
    packet += String(millis() - lastPassiveBatteryMs);
  } else {
    packet += "null";
  }

  packet += ",\"source\":\"";
  packet += WIFI_MOCK_TELEMETRY_ENABLED ? "esp32-mock" : FIRMWARE_VARIANT;
  packet += "\"";
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"can_bitrate\":";
  packet += String(CAN_BITRATE);
  packet += ",\"mcp_spi_hz\":";
  packet += String(MCP_SPI_HZ);
  packet += ",\"udp_telemetry_enabled\":";
  packet += UDP_TELEMETRY_ENABLED ? "true" : "false";
  packet += ",\"sse_client_flush_enabled\":";
  packet += SSE_CLIENT_FLUSH_ENABLED ? "true" : "false";
  packet += ",\"sse_backpressure_enabled\":";
  packet += SSE_BACKPRESSURE_CHECK_ENABLED ? "true" : "false";
  packet += ",\"sse_skipped\":";
  packet += String(sseSkippedFrames);
  packet += ",\"sse_dropped\":";
  packet += String(sseDroppedClients);
  packet += ",\"softap_stations\":";
  packet += String(WiFi.softAPgetStationNum());
  packet += ",\"link_quality_pct\":";
  packet += String(linkQuality());
  packet += ",\"rx_frames\":";
  packet += String(rxFrames);
  packet += ",\"rx_responses\":";
  packet += String(rxResponses);
  packet += ",\"tx_requests\":";
  packet += String(txRequests);
  packet += ",\"pid_timeouts\":";
  packet += String(pidTimeouts);
  packet += ",\"mcp_status\":";
  packet += String(canReady ? can.status() : 0);
  packet += ",\"mcp_errors\":";
  packet += String(canReady ? can.errorFlags() : 0);
  packet += ",\"mcp_rx_overflows\":";
  packet += String(mcpRxOverflowEvents);
  packet += ",\"mcp_rx_overflow_age_ms\":";
  if (lastMcpRxOverflowMs == 0) {
    packet += "null";
  } else {
    packet += String(millis() - lastMcpRxOverflowMs);
  }
  packet += ",\"mcp_reinit_attempts\":";
  packet += String(mcpReinitAttempts);
  packet += ",\"dropped_corrupt_frames\":";
  packet += String(droppedCorruptFrames);
  packet += "}";

  return packet;
}

String buildCanLogPacket() {
  uint32_t now = millis();
  String packet;
  packet.reserve(6500);
  packet += "{\"ms\":";
  packet += String(now);
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"listen_only\":";
  packet += CAN_LISTEN_ONLY ? "true" : "false";
  packet += ",\"filter_mode\":\"";
  packet += MCP_FILTER_IMPORTANT_IDS_ONLY ? "important-decoded-ids" : "accept-all";
  packet += "\"";
  packet += ",\"mcp_spi_hz\":";
  packet += String(MCP_SPI_HZ);
  packet += ",\"udp_telemetry_enabled\":";
  packet += UDP_TELEMETRY_ENABLED ? "true" : "false";
  packet += ",\"sse_client_flush_enabled\":";
  packet += SSE_CLIENT_FLUSH_ENABLED ? "true" : "false";
  packet += ",\"rx_frames\":";
  packet += String(rxFrames);
  packet += ",\"tx_requests\":";
  packet += String(txRequests);
  packet += ",\"decoded_rpm\":";
  if (isnan(telemetry.rpm)) {
    packet += "null";
  } else {
    packet += String(telemetry.rpm, 1);
  }
  packet += ",\"decoded_rpm_raw\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    packet += String(lastPassiveRpmRaw);
  }
  packet += ",\"decoded_rpm_raw_hex\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    packet += "\"0x";
    if (lastPassiveRpmRaw < 0x1000) packet += "0";
    if (lastPassiveRpmRaw < 0x0100) packet += "0";
    if (lastPassiveRpmRaw < 0x0010) packet += "0";
    packet += String(lastPassiveRpmRaw, HEX);
    packet += "\"";
  }
  packet += ",\"decoded_rpm_id_hex\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    packet += "\"0x";
    packet += String(lastPassiveRpmFrameId, HEX);
    packet += "\"";
  }
  packet += ",\"decoded_rpm_age_ms\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    packet += String(now - lastPassiveRpmMs);
  }
  appendFloat(packet, "decoded_speed_kph", telemetry.speed, 1);
  packet += ",\"decoded_speed_raw\":";
  if (!hasPassiveSpeed) {
    packet += "null";
  } else {
    packet += String(lastPassiveSpeedRaw);
  }
  packet += ",\"decoded_speed_raw_hex\":";
  if (!hasPassiveSpeed) {
    packet += "null";
  } else {
    appendHexWord(packet, lastPassiveSpeedRaw);
  }
  packet += ",\"decoded_speed_age_ms\":";
  if (!hasPassiveSpeed) {
    packet += "null";
  } else {
    packet += String(now - lastPassiveSpeedMs);
  }
  appendFloat(packet, "odometer_km", odometerKm(), 1);
  packet += ",\"odometer_m\":";
  packet += String(odometerMeters);
  packet += ",\"odometer_persisted_m\":";
  packet += String(odometerLastSavedMeters);
  packet += ",\"odometer_unsaved_m\":";
  packet += String(odometerUnsavedMeters());
  packet += ",\"odometer_prefs_ready\":";
  packet += odometerPrefsReady ? "true" : "false";
  packet += ",\"odometer_save_count\":";
  packet += String(odometerSaveCount);
  appendAllTripFields(packet);
  appendFloat(packet, "decoded_battery_v", telemetry.vbatt, 2);
  packet += ",\"decoded_battery_raw\":";
  if (!hasPassiveBattery) {
    packet += "null";
  } else {
    packet += String(lastPassiveBatteryRaw);
  }
  packet += ",\"decoded_battery_raw_hex\":";
  if (!hasPassiveBattery) {
    packet += "null";
  } else {
    packet += "\"0x";
    appendHexByte(packet, lastPassiveBatteryRaw);
    packet += "\"";
  }
  packet += ",\"decoded_battery_age_ms\":";
  if (!hasPassiveBattery) {
    packet += "null";
  } else {
    packet += String(now - lastPassiveBatteryMs);
  }
  packet += ",\"decoded_tps_raw\":";
  if (!hasPassiveTps) {
    packet += "null";
  } else {
    packet += String(lastPassiveTpsRaw);
  }
  appendFloat(packet, "decoded_tps_pct", lastPassiveTpsGrip, 1);
  appendFloat(packet, "decoded_tps_abs_pct", lastPassiveTpsAbs, 1);
  packet += ",\"decoded_tps_age_ms\":";
  if (!hasPassiveTps) {
    packet += "null";
  } else {
    packet += String(now - lastPassiveTpsMs);
  }
  packet += ",\"decoded_gear_raw\":";
  if (!hasPassiveGear) {
    packet += "null";
  } else {
    packet += String(lastPassiveGearRaw);
  }
  packet += ",\"decoded_gear\":";
  if (!hasPassiveGear) {
    packet += "null";
  } else {
    packet += "\"";
    packet += estimatedGear();
    packet += "\"";
  }
  packet += ",\"decoded_gear_age_ms\":";
  if (!hasPassiveGear) {
    packet += "null";
  } else {
    packet += String(now - lastPassiveGearMs);
  }
  packet += ",\"mcp_status\":";
  packet += String(canReady ? can.status() : 0);
  packet += ",\"mcp_errors\":";
  packet += String(canReady ? can.errorFlags() : 0);
  packet += ",\"mcp_rx_overflows\":";
  packet += String(mcpRxOverflowEvents);
  packet += ",\"mcp_rx_overflow_age_ms\":";
  if (lastMcpRxOverflowMs == 0) {
    packet += "null";
  } else {
    packet += String(now - lastMcpRxOverflowMs);
  }
  packet += ",\"mcp_reinit_attempts\":";
  packet += String(mcpReinitAttempts);
  packet += ",\"dropped_corrupt_frames\":";
  packet += String(droppedCorruptFrames);

  packet += ",\"recent\":[";
  uint32_t recentCount = recentCanStored < CAN_RECENT_COUNT ? recentCanStored : CAN_RECENT_COUNT;
  for (uint32_t n = 0; n < recentCount; n++) {
    size_t index = (recentCanWriteIndex + CAN_RECENT_COUNT - 1 - n) % CAN_RECENT_COUNT;
    const RecentCanFrame& frame = recentCanFrames[index];
    if (n > 0) packet += ',';
    packet += "{\"age_ms\":";
    packet += String(now - frame.ms);
    packet += ",\"id\":";
    packet += String(frame.id);
    packet += ",\"id_hex\":\"0x";
    packet += String(frame.id, HEX);
    packet += "\",\"extended\":";
    packet += frame.extended ? "true" : "false";
    packet += ",\"dlc\":";
    packet += String(frame.dlc);
    packet += ",\"data_hex\":\"";
    appendFrameDataHex(packet, frame.data, frame.dlc);
    packet += "\"}";
  }
  packet += "]";

  packet += ",\"ids\":[";
  bool first = true;
  for (size_t i = 0; i < CAN_ID_STATS_COUNT; i++) {
    const CanIdStat& stat = canIdStats[i];
    if (!stat.used) continue;
    if (!first) packet += ',';
    first = false;
    packet += "{\"id\":";
    packet += String(stat.id);
    packet += ",\"id_hex\":\"0x";
    packet += String(stat.id, HEX);
    packet += "\",\"extended\":";
    packet += stat.extended ? "true" : "false";
    packet += ",\"count\":";
    packet += String(stat.count);
    packet += ",\"last_age_ms\":";
    packet += String(now - stat.lastMs);
    packet += ",\"dlc\":";
    packet += String(stat.dlc);
    packet += ",\"data_hex\":\"";
    appendFrameDataHex(packet, stat.data, stat.dlc);
    packet += "\"}";
  }
  packet += "]}";

  return packet;
}

void sendTelemetry() {
  String packet = buildTelemetryPacket();

  if (UDP_TELEMETRY_ENABLED) {
    udp.beginPacket(UDP_BROADCAST, UDP_PORT);
    udp.write(reinterpret_cast<const uint8_t*>(packet.c_str()), packet.length());
    udp.endPacket();
  }

  if (SERIAL_TELEMETRY_DEBUG_ENABLED) {
    static uint32_t lastSerialPrintMs = 0;
    uint32_t serialIntervalMs = (captureActive || correlateActive) ? 2000 : 500;
    if (millis() - lastSerialPrintMs >= serialIntervalMs) {
      Serial.println(packet);
      lastSerialPrintMs = millis();
    }
  }
}

void drainCanQueue() {
  CanFrame frame;
  while (can.readFrame(frame)) {
    ingestCanFrame(frame);
  }
  serviceMcpRxOverflows();
  maintainCanHealth();
}

bool queryObdPid(uint8_t pid, uint8_t* out, uint8_t* outLen, uint32_t timeoutMs = PID_TIMEOUT_MS) {
  drainCanQueue();

  CanFrame tx;
  tx.id = 0x7DF;
  tx.extended = false;
  tx.dlc = 8;
  tx.data[0] = 0x02;
  tx.data[1] = 0x01;
  tx.data[2] = pid;
  tx.data[3] = 0x00;
  tx.data[4] = 0x00;
  tx.data[5] = 0x00;
  tx.data[6] = 0x00;
  tx.data[7] = 0x00;

  if (!can.sendFrame(tx)) {
    serviceMcpRxOverflows();
    return false;
  }

  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    CanFrame rx;
    if (!can.readFrame(rx)) {
      delay(1);
      continue;
    }
    ingestCanFrame(rx);

    if (rx.extended) continue;
    if (rx.id < 0x7E8 || rx.id > 0x7EF) continue;
    if (rx.dlc < 4) continue;
    if (rx.data[1] != 0x41 || rx.data[2] != pid) continue;

    uint8_t payloadBytes = rx.data[0];
    if (payloadBytes < 2) return false;
    uint8_t valueBytes = payloadBytes - 2;
    if (valueBytes > 5) valueBytes = 5;
    for (uint8_t i = 0; i < valueBytes; i++) {
      out[i] = rx.data[3 + i];
    }
    *outLen = valueBytes;
    rxResponses++;
    lastGoodResponseMs = millis();
    serviceMcpRxOverflows();
    return true;
  }

  pidTimeouts++;
  serviceMcpRxOverflows();
  return false;
}

bool getPid(uint8_t pid, uint8_t* b, uint8_t needed) {
  uint8_t len = 0;
  if (!queryObdPid(pid, b, &len)) return false;
  return len >= needed;
}

void applyPid(uint8_t pid, const uint8_t* b) {
  switch (pid) {
    case 0x0C:
      telemetry.rpm = ((static_cast<uint16_t>(b[0]) * 256) + b[1]) / 4.0f;
      break;
    case 0x05:
      telemetry.coolant = static_cast<float>(b[0]) - 40.0f;
      break;
    case 0x0F:
      telemetry.iat = static_cast<float>(b[0]) - 40.0f;
      break;
    case 0x0B:
      telemetry.map = static_cast<float>(b[0]);
      break;
    case 0x11: {
      float absTps = static_cast<float>(b[0]) * 100.0f / 255.0f;
      telemetry.tpsAbs = absTps;
      telemetry.tps = obdAbsTpsToGripPct(absTps);
      break;
    }
    case 0x0D:
      telemetry.speed = static_cast<float>(b[0]);
      break;
    case 0x42:
      telemetry.vbatt = ((static_cast<uint16_t>(b[0]) * 256) + b[1]) / 1000.0f;
      break;
  }
}

bool decodeObdPidValue(uint8_t pid, const uint8_t* b, uint8_t len, float& value, const char*& unit, uint16_t& raw) {
  raw = 0;
  unit = "";

  switch (pid) {
    case 0x0C:
      if (len < 2) return false;
      raw = (static_cast<uint16_t>(b[0]) << 8) | b[1];
      value = raw / 4.0f;
      unit = "rpm";
      return true;
    case 0x05:
      if (len < 1) return false;
      raw = b[0];
      value = static_cast<float>(b[0]) - 40.0f;
      unit = "C";
      return true;
    case 0x0F:
      if (len < 1) return false;
      raw = b[0];
      value = static_cast<float>(b[0]) - 40.0f;
      unit = "C";
      return true;
    case 0x0B:
      if (len < 1) return false;
      raw = b[0];
      value = static_cast<float>(b[0]);
      unit = "kPa";
      return true;
    case 0x11:
      if (len < 1) return false;
      raw = b[0];
      value = static_cast<float>(b[0]) * 100.0f / 255.0f;
      unit = "%";
      return true;
    case 0x0D:
      if (len < 1) return false;
      raw = b[0];
      value = static_cast<float>(b[0]);
      unit = "km/h";
      return true;
    case 0x42:
      if (len < 2) return false;
      raw = (static_cast<uint16_t>(b[0]) << 8) | b[1];
      value = raw / 1000.0f;
      unit = "V";
      return true;
  }

  return false;
}

bool tokenListContains(const String& csv, const char* token) {
  if (csv.length() == 0 || csv == "all") return true;

  int start = 0;
  while (start < static_cast<int>(csv.length())) {
    int end = csv.indexOf(',', start);
    if (end < 0) end = csv.length();

    String part = csv.substring(start, end);
    part.trim();
    part.toLowerCase();
    if (part == token) return true;

    start = end + 1;
  }
  return false;
}

bool obdLogPidEnabled(const ObdLogPid& spec, const String& requestedPids) {
  if (tokenListContains(requestedPids, spec.name)) return true;

  char pidHex[5];
  snprintf(pidHex, sizeof(pidHex), "%02x", spec.pid);
  return tokenListContains(requestedPids, pidHex);
}

bool startCorrelation(const String& requestedStage) {
  if (!fsReady || !canReady) return false;

  closeCaptureFile();
  closeCorrelationFile();
  if (LittleFS.exists(CORRELATE_FILE_PATH)) LittleFS.remove(CORRELATE_FILE_PATH);

  correlateStage = sanitizeCaptureToken(requestedStage, "rpm_idle");
  correlateRows = 0;
  correlateFrameRows = 0;
  correlateObdRows = 0;
  correlateObdOk = 0;
  correlateObdFail = 0;
  correlateSummaryRows = 0;
  correlateMarks = 0;
  correlateDroppedRows = 0;
  correlateFileBytes = 0;
  correlateBuffer = "";
  correlateBuffer.reserve(CORRELATE_FLUSH_BYTES + 768);
  correlateStartedMs = millis();
  correlateLastFlushMs = correlateStartedMs;
  correlateLastPidRequestMs = 0;
  correlateLastSummaryMs = 0;
  correlateLastOverflowLogMs = 0;
  correlateNextPidIndex = 0;
  correlateStartRxFrames = rxFrames;
  correlateStartTxRequests = txRequests;
  correlateStartRxResponses = rxResponses;
  correlateStartPidTimeouts = pidTimeouts;
  correlateStartMcpRxOverflows = mcpRxOverflowEvents;
  correlateMaxBytes = availableCorrelationLimitBytes();
  if (correlateMaxBytes < 96UL * 1024UL) {
    correlateMaxBytes = 0;
    return false;
  }

  correlateFile = LittleFS.open(CORRELATE_FILE_PATH, "w");
  if (!correlateFile) {
    correlateMaxBytes = 0;
    return false;
  }

  bool normalReady = can.configure(false);
  if (!normalReady) {
    correlateFile.close();
    canReady = can.configure(CAN_LISTEN_ONLY);
    return false;
  }
  canReady = true;

  uint32_t now = millis();
  for (size_t i = 0; i < sizeof(CORRELATE_PIDS) / sizeof(CORRELATE_PIDS[0]); i++) {
    CORRELATE_PIDS[i].lastRequestMs = now - CORRELATE_PIDS[i].intervalMs;
  }

  correlateActive = true;
  correlateBuffer += "type,ms,session_ms,stage,id_hex,extended,dlc,data_hex,pid_hex,pid_name,ok,value,unit,raw_hex,bytes,passive_rpm,passive_rpm_raw_hex,passive_rpm_id_hex,tps_raw,tps_pct,tps_abs_pct,gear,gear_raw,coolant_c,iat_c,map_kpa,speed_kph,battery_v,rx_frames,tx_requests,rx_responses,pid_timeouts,mcp_rx_overflows,label\n";
  appendCorrelationMarker("correlate_started");
  appendCorrelationSummary("start_snapshot");

  Serial.printf("CORRELATE_START path=%s stage=%s max_bytes=%lu\n",
                CORRELATE_FILE_PATH,
                correlateStage.c_str(),
                static_cast<unsigned long>(correlateMaxBytes));
  return true;
}

void markCorrelationStage(const String& requestedStage) {
  if (!correlateActive || !correlateFile) return;
  correlateStage = sanitizeCaptureToken(requestedStage, "stage");
  appendCorrelationMarker("stage_mark");
  appendCorrelationSummary("stage_snapshot");
  Serial.printf("CORRELATE_MARK stage=%s\n", correlateStage.c_str());
}

void runCorrelationPid(CorrelatePid& spec) {
  uint8_t b[5] = {0};
  uint8_t len = 0;
  bool ok = queryObdPid(spec.pid, b, &len, CORRELATE_PID_TIMEOUT_MS) && len >= spec.neededBytes;

  float value = NAN;
  const char* unit = "";
  uint16_t raw = 0;
  if (ok) {
    ok = decodeObdPidValue(spec.pid, b, len, value, unit, raw);
  }
  if (ok && spec.pid != 0x0C) {
    applyPid(spec.pid, b);
  }

  String bytes;
  if (len > 0) {
    appendFrameDataHex(bytes, b, len);
  }
  appendCorrelationObdRow(spec, ok, value, raw, bytes);
  correlateLastPidRequestMs = millis();
}

void maintainCorrelation() {
  if (!correlateActive) return;

  uint32_t now = millis();
  if (now - correlateStartedMs >= CORRELATE_MAX_SESSION_MS) {
    appendCorrelationMarker("auto_stop_max_session");
    closeCorrelationFile();
    return;
  }

  if (now - correlateLastSummaryMs >= CORRELATE_SUMMARY_INTERVAL_MS) {
    appendCorrelationSummary("periodic");
    correlateLastSummaryMs = now;
  }

  if (now - correlateLastPidRequestMs < CORRELATE_PID_COOLDOWN_MS) {
    if (now - correlateLastFlushMs >= CORRELATE_FLUSH_INTERVAL_MS) {
      flushCorrelationBuffer();
    }
    return;
  }

  size_t pidCount = sizeof(CORRELATE_PIDS) / sizeof(CORRELATE_PIDS[0]);
  for (size_t attempt = 0; attempt < pidCount; attempt++) {
    CorrelatePid& spec = CORRELATE_PIDS[correlateNextPidIndex];
    correlateNextPidIndex = (correlateNextPidIndex + 1) % pidCount;
    if (now - spec.lastRequestMs < spec.intervalMs) continue;

    spec.lastRequestMs = now;
    runCorrelationPid(spec);
    break;
  }

  if (millis() - correlateLastFlushMs >= CORRELATE_FLUSH_INTERVAL_MS) {
    flushCorrelationBuffer();
  }
}

bool isPassiveRpmOffValue(uint16_t rawRpm) {
  return rawRpm == 0xBFFD || rawRpm == 0xBFFE || rawRpm == 0xBFFF || rawRpm == 0xFFFF;
}

bool isPassiveRpmOffFrame(const CanFrame& frame, uint16_t rawRpm) {
  if (isPassiveRpmOffValue(rawRpm)) return true;

  // In the live log, engine-off settles at 0x287C. The same raw value can
  // appear briefly while the engine is still coasting, so include surrounding
  // bytes from the steady off pattern before forcing the displayed RPM to zero.
  if (rawRpm != 0x287C) return false;
  if (frame.id == 0x312) {
    return frame.data[0] == 0x40 && frame.data[1] == 0x00 && frame.data[6] == 0x30;
  }
  if (frame.id == 0x313) {
    return frame.data[0] == 0x00 && frame.data[1] == 0x00 && frame.data[6] == 0x00;
  }
  return false;
}

void publishPassiveRpm(uint32_t frameId, uint16_t rawRpm, uint32_t now, float rpm) {
  hasPassiveRpm = true;
  lastPassiveRpmRaw = rawRpm;
  lastPassiveRpmFrameId = frameId;
  lastPassiveRpmMs = now;
  telemetry.rpm = rpm;
  lastGoodResponseMs = now;
}

bool publishPassive301TachIfPaired(uint32_t now) {
  if (!hasPassive301Tach || !hasPassive302RpmCompanion) return false;
  if (now - lastPassive301TachMs > PASSIVE_RPM_PAIR_MAX_AGE_MS) return false;
  if (now - lastPassive302RpmCompanionMs > PASSIVE_RPM_PAIR_MAX_AGE_MS) return false;

  publishPassiveRpm(0x301, lastPassive301TachRaw, now,
                    static_cast<float>(lastPassive301TachRaw) * PASSIVE_301_TACH_RPM_SCALE);
  return true;
}

bool applyPassiveCanFrame(const CanFrame& frame) {
  if (frame.extended) return false;

  uint32_t now = millis();

  // Confirmed/high-confidence passive hex decodes. Keep this group separate
  // from RPM experiments so bench validation can test known IDs first.

  if (frame.id == 0x301 && frame.dlc >= 3) {
    // Finalized passive TPS: 0x301 byte 2 is rider throttle opening.
    // byte=0 means closed grip; byte=255 means fully open. For comparison with
    // standard OBD PID 0x11, map it onto the observed absolute TPS range where
    // closed idle is OBD raw 27 (~10.6%).
    uint8_t rawTps = frame.data[2];
    float gripPct = passiveTpsGripPct(rawTps);
    float absPct = passiveTpsAbsPct(rawTps);
    hasPassiveTps = true;
    lastPassiveTpsRaw = rawTps;
    lastPassiveTpsGrip = gripPct;
    lastPassiveTpsAbs = absPct;
    lastPassiveTpsMs = now;
    telemetry.tps = gripPct;
    telemetry.tpsAbs = absPct;

    lastPassive301TachRaw = frame.data[0];
    lastPassive301TachMs = now;
    hasPassive301Tach = true;
    publishPassiveRpm(0x301, lastPassive301TachRaw, now,
                      static_cast<float>(lastPassive301TachRaw) * PASSIVE_301_TACH_RPM_SCALE);
    return true;
  }

  // High-confidence temperature/MAP group from OBD correlation:
  // coolant = 0.099314 * signed_be16(bytes 0,1) + 2983.421676
  // IAT = 0.095760 * byte 5 + 34.038803
  // MAP ~= byte 6 + 1 kPa
  if (frame.id == 0x302 && frame.dlc >= 7) {
    int16_t coolantRaw = static_cast<int16_t>((static_cast<uint16_t>(frame.data[0]) << 8) |
                                              frame.data[1]);
    hasPassiveCoolant = true;
    lastPassiveCoolantRaw = coolantRaw;
    lastPassiveCoolantMs = now;
    telemetry.coolant = passiveCoolantC(coolantRaw);

    hasPassiveIat = true;
    lastPassiveIatRaw = frame.data[5];
    lastPassiveIatMs = now;
    telemetry.iat = passiveIatC(frame.data[5]);

    hasPassiveMap = true;
    lastPassiveMapRaw = frame.data[6];
    lastPassiveMapMs = now;
    telemetry.map = passiveMapKpa(frame.data[6]);

    if (frame.dlc >= 8) {
      lastPassive302RpmB1 = frame.data[1];
      lastPassive302RpmB3 = frame.data[3];
      lastPassive302RpmB7 = frame.data[7];
      lastPassive302RpmCompanionMs = now;
      hasPassive302RpmCompanion = true;
      if (publishPassive301TachIfPaired(now)) return true;
    }
  }

  // Finalized passive gear: 0x447 byte 5 is 0=N, 1..6=gear number.
  if (frame.id == 0x447 && frame.dlc >= 6 && frame.data[5] <= 6) {
    hasPassiveGear = true;
    lastPassiveGearRaw = frame.data[5];
    lastPassiveGearMs = now;
  }

  // Finalized passive speedometer: bench testing confirmed 0x30C bytes 0,1 as
  // big-endian wheel-speed raw, with raw ~= displayed km/h * 118.
  if (frame.id == 0x30C && frame.dlc >= 2) {
    uint16_t rawSpeed = (static_cast<uint16_t>(frame.data[0]) << 8) | frame.data[1];
    hasPassiveSpeed = true;
    lastPassiveSpeedRaw = rawSpeed;
    lastPassiveSpeedMs = now;
    telemetry.speed = static_cast<float>(rawSpeed) / PASSIVE_30C_SPEED_KPH_SCALE;
    lastGoodResponseMs = now;
  }

  // Candidate passive ECU/battery voltage. Correlation against OBD PID 0x42
  // suggests 0x303 byte 1 carries voltage in 0.1 V units; keep the source
  // labelled as candidate until checked against a multimeter across a wider
  // battery range.
  if (frame.id == 0x303 && frame.dlc >= 2) {
    float volts = static_cast<float>(frame.data[1]) * PASSIVE_303_BATTERY_V_SCALE;
    if (volts >= 9.0f && volts <= 16.5f) {
      hasPassiveBattery = true;
      lastPassiveBatteryRaw = frame.data[1];
      lastPassiveBatteryMs = now;
      telemetry.vbatt = volts;
      lastGoodResponseMs = now;
    }
  }

  if (frame.dlc < 4) return false;

  // Fallback only. Bench testing showed the cluster trusts 0x301 b0 plus
  // 0x302 b1,b3,b7, not 0x310. Keep 0x310 for startup/off-state visibility
  // when the paired 0x301/0x302 tach is not fresh yet.
  if (frame.id == 0x310 && frame.dlc >= 6 && frame.data[4] == frame.data[5]) {
    uint16_t rawRpm = frame.data[4];
    if (!hasPassiveRpm || now - lastPassiveRpmMs > 250) {
      publishPassiveRpm(frame.id, rawRpm, now, static_cast<float>(rawRpm) * PASSIVE_310_BUCKET_RPM_SCALE);
      return true;
    }
  }

  // Observed on the Dominar live bus:
  // idle 0x2EE2 / 8 = ~1500 rpm, but higher rev samples can be about half
  // the bike tach. Keep this source only for the explicit engine-off sentinel.
  if (frame.id == 0x313 || frame.id == 0x312) {
    uint16_t rawRpm = (static_cast<uint16_t>(frame.data[2]) << 8) | frame.data[3];
    if (isPassiveRpmOffFrame(frame, rawRpm)) {
      publishPassiveRpm(frame.id, rawRpm, now, 0.0f);
      return true;
    }
  }
  return false;
}

void pollOnePid() {
  static size_t index = 0;
  const PidRequest& req = PID_SCHEDULE[index];
  index = (index + 1) % (sizeof(PID_SCHEDULE) / sizeof(PID_SCHEDULE[0]));

  uint8_t b[5] = {0};
  if (getPid(req.pid, b, req.neededBytes)) {
    applyPid(req.pid, b);
  }
}

void processPassiveCanFrames() {
  if (!CAN_LISTEN_ONLY || WIFI_MOCK_TELEMETRY_ENABLED) return;
  if (!canReady) {
    maintainCanHealth();
    return;
  }

  CanFrame frame;
  uint8_t drained = 0;
  static uint32_t lastRpmDebugMs = 0;
  while (drained < CORRELATE_DRAIN_LIMIT && can.readFrame(frame)) {
    bool rpmUpdated = ingestCanFrame(frame);
    if (SERIAL_RPM_DEBUG_ENABLED && !captureActive && !correlateActive &&
        rpmUpdated && millis() - lastRpmDebugMs >= 250) {
      Serial.printf("RPM id=0x%lX raw=0x%04X rpm=%.1f data=",
                    static_cast<unsigned long>(lastPassiveRpmFrameId),
                    lastPassiveRpmRaw,
                    telemetry.rpm);
      for (uint8_t i = 0; i < frame.dlc; i++) {
        if (i > 0) Serial.print(' ');
        if (frame.data[i] < 0x10) Serial.print('0');
        Serial.print(frame.data[i], HEX);
      }
      Serial.println();
      lastRpmDebugMs = millis();
    }
    drained++;
  }

  serviceMcpRxOverflows();
  maintainCanHealth();
}

void printWiringSummary() {
  Serial.println();
  Serial.println("Expected MCP2515 wiring:");
  Serial.printf("  VCC -> ESP32 3V3, GND -> GND\n");
  Serial.printf("  SCK -> GPIO%d, SI/MOSI -> GPIO%d, SO/MISO -> GPIO%d\n",
                SPI_SCK_PIN, SPI_MOSI_PIN, SPI_MISO_PIN);
  Serial.printf("  CS -> GPIO%d, INT -> GPIO%d\n", CAN_CS_PIN, CAN_INT_PIN);
  Serial.println("If your module is connected to the bike, remove the 120 ohm jumper.");
  Serial.println();
}

void setupOdometer() {
  odometerPrefsReady = odometerPrefs.begin(ODOMETER_PREF_NAMESPACE, false);
  if (!odometerPrefsReady) {
    Serial.println("Odometer NVS: unavailable, using RAM-only value");
    return;
  }

  bool hadStoredValue = odometerPrefs.isKey(ODOMETER_PREF_METERS_KEY);
  odometerMeters = hadStoredValue
                       ? odometerPrefs.getUInt(ODOMETER_PREF_METERS_KEY, ODOMETER_INITIAL_METERS)
                       : ODOMETER_INITIAL_METERS;
  odometerLastSavedMeters = odometerMeters;
  odometerLastSaveMs = millis();
  odometerFractionMeters = 0.0f;

  if (!hadStoredValue) {
    saveOdometer(true);
  }

  Serial.printf("Odometer: %.1f km (%s)\n",
                odometerKm(),
                odometerPrefsReady ? "persistent" : "RAM-only");
}

void setupTrips() {
  tripLastTickMs = millis();
  tripLastSaveMs = millis();
  if (!odometerPrefsReady) {
    Serial.println("Trip computer NVS: unavailable, using RAM-only values");
    return;
  }

  bool initializedAny = false;
  for (uint8_t i = 0; i < TRIP_COUNT; i++) {
    TripState& trip = trips[i];
    bool hadStoredValue = odometerPrefs.isKey(TRIP_DISTANCE_PREF_KEYS[i]) ||
                          odometerPrefs.isKey(TRIP_FUEL_PREF_KEYS[i]) ||
                          odometerPrefs.isKey(TRIP_SECONDS_PREF_KEYS[i]);
    trip.distanceMeters = odometerPrefs.getUInt(TRIP_DISTANCE_PREF_KEYS[i], 0);
    trip.fuelMilliLiters = odometerPrefs.getUInt(TRIP_FUEL_PREF_KEYS[i], 0);
    trip.seconds = odometerPrefs.getUInt(TRIP_SECONDS_PREF_KEYS[i], 0);
    trip.savedDistanceMeters = trip.distanceMeters;
    trip.savedFuelMilliLiters = trip.fuelMilliLiters;
    trip.savedSeconds = trip.seconds;
    trip.distanceFractionMeters = 0.0f;
    trip.fuelFractionMilliLiters = 0.0f;
    if (!hadStoredValue) {
      initializedAny = true;
    }

    Serial.printf("Trip %u: %.1f km, %lu s, %.1f kmpl (%s)\n",
                  static_cast<unsigned int>(i + 1),
                  tripDistanceKm(trip),
                  static_cast<unsigned long>(trip.seconds),
                  tripKmpl(trip),
                  odometerPrefsReady ? "persistent" : "RAM-only");
  }

  if (initializedAny) {
    saveAllTrips(true);
  }
}

void startMdns() {
  if (mdnsStarted) return;
  if (!MDNS.begin(MDNS_HOSTNAME)) {
    Serial.println("mDNS startup failed; use the printed IP address instead.");
    return;
  }
  MDNS.addService("http", "tcp", 80);
  mdnsStarted = true;
  Serial.printf("Telemetry hostname: http://%s.local\n", MDNS_HOSTNAME);
}

void setupWiFi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);
  // AP mode only: phone joins D400Telemetry directly. No iPhone hotspot / STA.
  WiFi.setSleep(false);

  if (!WiFi.softAP(AP_SSID, AP_PASS)) {
    Serial.println("Failed to start Wi-Fi AP.");
  }
  if (UDP_TELEMETRY_ENABLED) {
    udp.begin(UDP_PORT);
  }

  Serial.print("Wi-Fi AP: ");
  Serial.println(AP_SSID);
  Serial.print("Password: ");
  Serial.println(AP_PASS);
  Serial.print("AP IP: ");
  Serial.println(WiFi.softAPIP());
  Serial.println("Dashboard: http://192.168.4.1");
  startMdns();

  if (UDP_TELEMETRY_ENABLED) {
    Serial.printf("UDP telemetry broadcast: %s:%u\n",
                  UDP_BROADCAST.toString().c_str(), UDP_PORT);
  } else {
    Serial.println("UDP telemetry broadcast: disabled");
  }
}

bool streamFsFile(const char* path, const char* contentType) {
  if (!fsReady || !LittleFS.exists(path)) return false;

  File file = LittleFS.open(path, "r");
  if (!file) return false;

  http.sendHeader("Cache-Control", "no-store");
  http.streamFile(file, contentType);
  file.close();
  return true;
}

void handleRoot() {
  if (streamFsFile("/index.html", "text/html; charset=utf-8")) return;

  http.sendHeader("Cache-Control", "no-store");
  http.send_P(200, "text/html; charset=utf-8", TEST_PAGE);
}

void handleTestPage() {
  http.sendHeader("Cache-Control", "no-store");
  http.send_P(200, "text/html; charset=utf-8", TEST_PAGE);
}

void handleTelemetryJson() {
  if (WIFI_MOCK_TELEMETRY_ENABLED) {
    updateMockTelemetry();
  } else {
    processPassiveCanFrames();
  }
  maintainOdometer();
  maintainTripComputer();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildTelemetryPacket());
}

void handleCanLogJson() {
  processPassiveCanFrames();
  maintainOdometer();
  maintainTripComputer();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildCanLogPacket());
}

void handleObdRpmTest() {
  processPassiveCanFrames();

  float passiveRpm = telemetry.rpm;
  uint16_t passiveRaw = lastPassiveRpmRaw;
  uint32_t passiveFrameId = lastPassiveRpmFrameId;
  uint32_t txBefore = txRequests;
  uint32_t rxBefore = rxResponses;
  uint32_t timeoutBefore = pidTimeouts;

  String packet;
  packet.reserve(1600);
  packet += "{\"ms\":";
  packet += String(millis());
  packet += ",\"warning\":\"manual active CAN test; sends standard OBD Mode 01 PID 0C requests\"";
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"passive_rpm\":";
  if (isnan(passiveRpm)) {
    packet += "null";
  } else {
    packet += String(passiveRpm, 1);
  }
  packet += ",\"passive_rpm_raw_hex\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    appendHexWord(packet, passiveRaw);
  }
  packet += ",\"passive_rpm_id_hex\":";
  if (!hasPassiveRpm) {
    packet += "null";
  } else {
    packet += "\"0x";
    packet += String(passiveFrameId, HEX);
    packet += "\"";
  }

  if (!canReady) {
    packet += ",\"ok\":false,\"error\":\"can_not_ready\"}";
    http.sendHeader("Cache-Control", "no-store");
    http.send(200, "application/json", packet);
    return;
  }

  bool normalReady = can.configure(false);
  packet += ",\"normal_mode_ready\":";
  packet += normalReady ? "true" : "false";
  packet += ",\"samples\":[";

  bool first = true;
  if (normalReady) {
    delay(8);
    for (uint8_t i = 0; i < OBD_RPM_TEST_SAMPLES; i++) {
      uint8_t b[5] = {0};
      uint8_t len = 0;
      bool ok = queryObdPid(0x0C, b, &len, OBD_RPM_TEST_TIMEOUT_MS) && len >= 2;
      if (!first) packet += ',';
      first = false;
      packet += "{\"index\":";
      packet += String(i + 1);
      packet += ",\"ok\":";
      packet += ok ? "true" : "false";
      if (ok) {
        uint16_t raw = (static_cast<uint16_t>(b[0]) << 8) | b[1];
        float rpm = raw / 4.0f;
        packet += ",\"raw\":";
        packet += String(raw);
        packet += ",\"raw_hex\":";
        appendHexWord(packet, raw);
        packet += ",\"rpm\":";
        packet += String(rpm, 2);
        packet += ",\"bytes\":\"";
        appendFrameDataHex(packet, b, len);
        packet += "\"";
      }
      packet += "}";
      delay(25);
    }
  }
  packet += "]";

  bool restored = can.configure(CAN_LISTEN_ONLY);
  canReady = restored;
  packet += ",\"restored_listen_only\":";
  packet += restored ? "true" : "false";
  packet += ",\"tx_requests_delta\":";
  packet += String(txRequests - txBefore);
  packet += ",\"rx_responses_delta\":";
  packet += String(rxResponses - rxBefore);
  packet += ",\"pid_timeouts_delta\":";
  packet += String(pidTimeouts - timeoutBefore);
  packet += ",\"tx_requests_total\":";
  packet += String(txRequests);
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleObdLogTest() {
  processPassiveCanFrames();

  uint32_t seconds = OBD_LOG_DEFAULT_SECONDS;
  if (http.hasArg("seconds")) {
    int requested = http.arg("seconds").toInt();
    if (requested > 0) {
      seconds = static_cast<uint32_t>(requested);
    }
  }
  if (seconds > OBD_LOG_MAX_SECONDS) seconds = OBD_LOG_MAX_SECONDS;
  uint32_t durationMs = seconds * 1000UL;

  String requestedPids = "all";
  if (http.hasArg("pids")) {
    requestedPids = http.arg("pids");
  } else if (http.hasArg("mode")) {
    requestedPids = http.arg("mode");
  }
  requestedPids.toLowerCase();

  String activePidList;
  size_t activePidCount = 0;
  for (size_t i = 0; i < sizeof(OBD_LOG_PIDS) / sizeof(OBD_LOG_PIDS[0]); i++) {
    const ObdLogPid& spec = OBD_LOG_PIDS[i];
    if (!obdLogPidEnabled(spec, requestedPids)) continue;
    if (activePidList.length() > 0) activePidList += ',';
    activePidList += spec.name;
    activePidCount++;
  }

  if (activePidCount == 0) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(200, "text/plain", "OBD log failed: no matching PIDs. Use pids=rpm,tps,coolant,iat,speed,map,ecu_voltage\n");
    return;
  }

  uint32_t txBefore = txRequests;
  uint32_t rxBefore = rxResponses;
  uint32_t timeoutBefore = pidTimeouts;
  uint32_t startMs = millis();
  uint32_t okCount = 0;
  uint32_t failCount = 0;
  uint32_t loops = 0;

  Serial.println();
  Serial.printf("OBD_LOG_START ms=%lu duration_s=%lu pids=%s\n",
                static_cast<unsigned long>(startMs),
                static_cast<unsigned long>(seconds),
                activePidList.c_str());
  Serial.println("OBD_CSV,ms,loop,passive_rpm,passive_raw_hex,passive_id_hex,pid_hex,name,ok,value,unit,obd_raw_hex,bytes");

  if (!canReady) {
    Serial.println("OBD_LOG_ERROR can_not_ready");
    http.sendHeader("Cache-Control", "no-store");
    http.send(200, "text/plain", "OBD log failed: CAN not ready\n");
    return;
  }

  bool normalReady = can.configure(false);
  if (!normalReady) {
    Serial.println("OBD_LOG_ERROR normal_mode_failed");
    can.configure(CAN_LISTEN_ONLY);
    http.sendHeader("Cache-Control", "no-store");
    http.send(200, "text/plain", "OBD log failed: could not enter normal CAN mode\n");
    return;
  }

  delay(8);
  while (millis() - startMs < durationMs) {
    loops++;
    for (size_t i = 0; i < sizeof(OBD_LOG_PIDS) / sizeof(OBD_LOG_PIDS[0]); i++) {
      const ObdLogPid& spec = OBD_LOG_PIDS[i];
      if (!obdLogPidEnabled(spec, requestedPids)) continue;

      uint8_t b[5] = {0};
      uint8_t len = 0;
      bool ok = queryObdPid(spec.pid, b, &len, OBD_LOG_PID_TIMEOUT_MS) && len >= spec.neededBytes;

      float value = NAN;
      const char* unit = "";
      uint16_t raw = 0;
      if (ok) {
        ok = decodeObdPidValue(spec.pid, b, len, value, unit, raw);
      }
      if (ok && spec.pid != 0x0C) {
        applyPid(spec.pid, b);
      }

      String bytes;
      if (len > 0) {
        appendFrameDataHex(bytes, b, len);
      }

      Serial.printf("OBD_CSV,%lu,%lu,",
                    static_cast<unsigned long>(millis()),
                    static_cast<unsigned long>(loops));
      if (isnan(telemetry.rpm)) {
        Serial.print("null");
      } else {
        Serial.print(telemetry.rpm, 1);
      }
      Serial.printf(",0x%04X,0x%lX,0x%02X,%s,%u,",
                    hasPassiveRpm ? lastPassiveRpmRaw : 0,
                    static_cast<unsigned long>(hasPassiveRpm ? lastPassiveRpmFrameId : 0),
                    spec.pid,
                    spec.name,
                    ok ? 1 : 0);
      if (ok) {
        Serial.print(value, 2);
        Serial.printf(",%s,0x%04X,%s\n", unit, raw, bytes.c_str());
        okCount++;
      } else {
        Serial.printf("null,,,%s\n", bytes.c_str());
        failCount++;
      }

      delay(10);
      yield();
      if (millis() - startMs >= durationMs) break;
    }
  }

  bool restored = can.configure(CAN_LISTEN_ONLY);
  canReady = restored;

  Serial.printf("OBD_LOG_END ms=%lu loops=%lu ok=%lu fail=%lu tx_delta=%lu rx_delta=%lu timeout_delta=%lu restored_listen_only=%u\n",
                static_cast<unsigned long>(millis()),
                static_cast<unsigned long>(loops),
                static_cast<unsigned long>(okCount),
                static_cast<unsigned long>(failCount),
                static_cast<unsigned long>(txRequests - txBefore),
                static_cast<unsigned long>(rxResponses - rxBefore),
                static_cast<unsigned long>(pidTimeouts - timeoutBefore),
                restored ? 1 : 0);
  Serial.println();

  String response;
  response.reserve(360);
  response += "OBD log complete. Check serial monitor for OBD_CSV rows.\n";
  response += "duration_s=";
  response += String(seconds);
  response += "\nloops=";
  response += String(loops);
  response += "\npids=";
  response += activePidList;
  response += "\nok=";
  response += String(okCount);
  response += "\nfail=";
  response += String(failCount);
  response += "\ntx_requests_delta=";
  response += String(txRequests - txBefore);
  response += "\nrx_responses_delta=";
  response += String(rxResponses - rxBefore);
  response += "\npid_timeouts_delta=";
  response += String(pidTimeouts - timeoutBefore);
  response += "\nrestored_listen_only=";
  response += restored ? "true" : "false";
  response += "\n";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "text/plain", response);
}

void handleCapturePage() {
  http.sendHeader("Cache-Control", "no-store");
  http.send_P(200, "text/html; charset=utf-8", CAPTURE_PAGE);
}

void handleCaptureStatus() {
  processPassiveCanFrames();
  maintainCapture();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildCaptureStatusPacket());
}

void handleCaptureStart() {
  processPassiveCanFrames();
  String stage = http.hasArg("stage") ? http.arg("stage") : "baseline";
  bool ok = startCapture(stage);

  String packet;
  packet.reserve(520);
  packet += "{\"ok\":";
  packet += ok ? "true" : "false";
  if (!ok) {
    packet += ",\"error\":\"capture_start_failed_or_not_enough_space\"";
  }
  packet += ",\"status\":";
  packet += buildCaptureStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(ok ? 200 : 500, "application/json", packet);
}

void handleCaptureMark() {
  processPassiveCanFrames();
  if (!captureActive) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(409, "application/json", "{\"ok\":false,\"error\":\"capture_not_active\"}");
    return;
  }

  String stage = http.hasArg("stage") ? http.arg("stage") : captureStage;
  String label = http.hasArg("label") ? http.arg("label") : stage;
  markCapture(stage, label);

  String packet;
  packet.reserve(520);
  packet += "{\"ok\":true,\"status\":";
  packet += buildCaptureStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleCaptureStop() {
  processPassiveCanFrames();
  closeCaptureFile();

  String packet;
  packet.reserve(520);
  packet += "{\"ok\":true,\"status\":";
  packet += buildCaptureStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleCaptureDownload() {
  processPassiveCanFrames();
  closeCaptureFile();

  if (!fsReady || !LittleFS.exists(CAPTURE_FILE_PATH)) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(404, "text/plain", "capture file not found\n");
    return;
  }

  File file = LittleFS.open(CAPTURE_FILE_PATH, "r");
  if (!file) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(500, "text/plain", "capture file open failed\n");
    return;
  }

  http.sendHeader("Cache-Control", "no-store");
  http.sendHeader("Content-Disposition", "attachment; filename=\"d400_capture.csv\"");
  http.streamFile(file, "text/csv");
  file.close();
}

void handleCaptureProbe() {
  uint32_t durationMs = 1500;
  if (http.hasArg("ms")) {
    int requested = http.arg("ms").toInt();
    if (requested > 0) durationMs = static_cast<uint32_t>(requested);
  }
  if (durationMs > 5000) durationMs = 5000;

  uint32_t startMs = millis();
  uint32_t rxBefore = rxFrames;
  uint32_t rowsBefore = captureRows;
  uint32_t overflowBefore = mcpRxOverflowEvents;

  while (millis() - startMs < durationMs) {
    processPassiveCanFrames();
    maintainCapture();
    delay(2);
    yield();
  }

  String packet;
  packet.reserve(520);
  packet += "{\"ok\":true,\"duration_ms\":";
  packet += String(millis() - startMs);
  packet += ",\"capture_active\":";
  packet += captureActive ? "true" : "false";
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"rx_delta\":";
  packet += String(rxFrames - rxBefore);
  packet += ",\"row_delta\":";
  packet += String(captureRows - rowsBefore);
  packet += ",\"overflow_delta\":";
  packet += String(mcpRxOverflowEvents - overflowBefore);
  packet += ",\"status\":";
  packet += buildCaptureStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleCorrelationPage() {
  http.sendHeader("Cache-Control", "no-store");
  http.send_P(200, "text/html; charset=utf-8", CORRELATE_PAGE);
}

void handleCorrelationStatus() {
  processPassiveCanFrames();
  maintainCorrelation();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildCorrelationStatusPacket());
}

void handleCorrelationStart() {
  processPassiveCanFrames();
  String stage = http.hasArg("stage") ? http.arg("stage") : "rpm_idle";
  bool ok = startCorrelation(stage);

  String packet;
  packet.reserve(620);
  packet += "{\"ok\":";
  packet += ok ? "true" : "false";
  if (!ok) {
    packet += ",\"error\":\"correlation_start_failed_check_can_or_space\"";
  }
  packet += ",\"status\":";
  packet += buildCorrelationStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(ok ? 200 : 500, "application/json", packet);
}

void handleCorrelationMark() {
  processPassiveCanFrames();
  if (!correlateActive) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(409, "application/json", "{\"ok\":false,\"error\":\"correlation_not_active\"}");
    return;
  }

  String stage = http.hasArg("stage") ? http.arg("stage") : correlateStage;
  markCorrelationStage(stage);

  String packet;
  packet.reserve(620);
  packet += "{\"ok\":true,\"status\":";
  packet += buildCorrelationStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleCorrelationStop() {
  processPassiveCanFrames();
  if (correlateActive) {
    appendCorrelationMarker("manual_stop");
    appendCorrelationSummary("stop_snapshot");
  }
  closeCorrelationFile();

  String packet;
  packet.reserve(620);
  packet += "{\"ok\":true,\"status\":";
  packet += buildCorrelationStatusPacket();
  packet += "}";

  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

void handleCorrelationDownload() {
  processPassiveCanFrames();
  if (correlateActive) {
    appendCorrelationMarker("download_stop");
    appendCorrelationSummary("download_snapshot");
  }
  closeCorrelationFile();

  if (!fsReady || !LittleFS.exists(CORRELATE_FILE_PATH)) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(404, "text/plain", "correlation file not found\n");
    return;
  }

  File file = LittleFS.open(CORRELATE_FILE_PATH, "r");
  if (!file) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(500, "text/plain", "correlation file open failed\n");
    return;
  }

  http.sendHeader("Cache-Control", "no-store");
  http.sendHeader("Content-Disposition", "attachment; filename=\"d400_correlation.csv\"");
  http.streamFile(file, "text/csv");
  file.close();
}

void handleHealth() {
  String packet;
  packet.reserve(280);
  packet += "{\"ok\":true";
  packet += ",\"variant\":\"";
  packet += WIFI_MOCK_TELEMETRY_ENABLED ? "esp32-mock" : FIRMWARE_VARIANT;
  packet += "\"";
  packet += ",\"ms\":";
  packet += String(millis());
  packet += ",\"sse_active\":";
  packet += sseClientActive ? "true" : "false";
  packet += ",\"sse_backpressure_enabled\":";
  packet += SSE_BACKPRESSURE_CHECK_ENABLED ? "true" : "false";
  packet += ",\"sse_skipped\":";
  packet += String(sseSkippedFrames);
  packet += ",\"sse_dropped\":";
  packet += String(sseDroppedClients);
  packet += ",\"softap_stations\":";
  packet += String(WiFi.softAPgetStationNum());
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += "}";
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", packet);
}

String buildOdometerStatusPacket(bool ok, const char* error = nullptr) {
  String packet;
  packet.reserve(320);
  packet += "{\"ok\":";
  packet += ok ? "true" : "false";
  if (error) {
    packet += ",\"error\":\"";
    packet += error;
    packet += "\"";
  }
  appendFloat(packet, "odometer_km", odometerKm(), 1);
  packet += ",\"odometer_m\":";
  packet += String(odometerMeters);
  packet += ",\"odometer_persisted_m\":";
  packet += String(odometerLastSavedMeters);
  packet += ",\"odometer_unsaved_m\":";
  packet += String(odometerUnsavedMeters());
  packet += ",\"odometer_prefs_ready\":";
  packet += odometerPrefsReady ? "true" : "false";
  packet += ",\"odometer_save_count\":";
  packet += String(odometerSaveCount);
  packet += "}";
  return packet;
}

void handleOdometerStatus() {
  processPassiveCanFrames();
  maintainOdometer();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildOdometerStatusPacket(true));
}

void handleOdometerSet() {
  processPassiveCanFrames();
  maintainOdometer();

  if (!http.hasArg("km")) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(400, "application/json", buildOdometerStatusPacket(false, "missing_km"));
    return;
  }

  String kmText = http.arg("km");
  float km = kmText.toFloat();
  if (isnan(km) || km < 0.0f || km > 999999.9f) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(400, "application/json", buildOdometerStatusPacket(false, "invalid_km"));
    return;
  }

  odometerMeters = static_cast<uint32_t>(lroundf(km * 1000.0f));
  odometerFractionMeters = 0.0f;
  odometerLastUpdateMs = millis();
  odometerWasMoving = false;
  bool saved = saveOdometer(true);

  http.sendHeader("Cache-Control", "no-store");
  http.send(saved ? 200 : 500,
            "application/json",
            buildOdometerStatusPacket(saved, saved ? nullptr : "save_failed"));
}

String buildTripStatusPacket(bool ok, const char* error = nullptr) {
  String packet;
  packet.reserve(720);
  packet += "{\"ok\":";
  packet += ok ? "true" : "false";
  if (error) {
    packet += ",\"error\":\"";
    packet += error;
    packet += "\"";
  }
  packet += ",\"ms\":";
  packet += String(millis());
  appendAllTripFields(packet);
  packet += "}";
  return packet;
}

int requestedTripSlot() {
  String slotText;
  if (http.hasArg("slot")) {
    slotText = http.arg("slot");
  } else if (http.hasArg("trip")) {
    slotText = http.arg("trip");
  } else {
    return 1;
  }
  int slot = slotText.toInt();
  if (slot < 1 || slot > TRIP_COUNT) return -1;
  return slot;
}

void handleTripStatus() {
  processPassiveCanFrames();
  maintainOdometer();
  maintainTripComputer();
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildTripStatusPacket(true));
}

void handleTripReset() {
  processPassiveCanFrames();
  maintainOdometer();
  maintainTripComputer();

  int slot = requestedTripSlot();
  if (slot < 1) {
    http.sendHeader("Cache-Control", "no-store");
    http.send(400, "application/json", buildTripStatusPacket(false, "invalid_trip"));
    return;
  }

  resetTrip(static_cast<uint8_t>(slot - 1));
  bool saved = saveTrip(static_cast<uint8_t>(slot - 1), true);
  bool ok = saved || !odometerPrefsReady;
  http.sendHeader("Cache-Control", "no-store");
  http.send(ok ? 200 : 500,
            "application/json",
            buildTripStatusPacket(ok, ok ? nullptr : "save_failed"));
}

void closeSseClient() {
  if (!sseClientActive) return;
  sseClient.stop();
  sseClientActive = false;
}

// True when the SSE socket can accept a send without waiting. Arduino-ESP32's
// WiFiClient::write() otherwise select()-retries for up to ~10 s on a full
// TCP window, which freezes loop() / CAN ingest / the packet `ms` stamp.
bool sseSocketWritable() {
  const int sock = sseClient.fd();
  if (sock < 0) return false;

  fd_set writeSet;
  FD_ZERO(&writeSet);
  FD_SET(sock, &writeSet);
  timeval tv;
  tv.tv_sec = 0;
  tv.tv_usec = 0;
  const int ready = ::select(sock + 1, nullptr, &writeSet, nullptr, &tv);
  return ready > 0 && FD_ISSET(sock, &writeSet);
}

void noteSseSkipOrStall() {
  sseSkippedFrames++;
  if (millis() - sseLastAcceptedMs >= SSE_STALL_TIMEOUT_MS) {
    sseDroppedClients++;
    closeSseClient();
  }
}

// Adopts the request socket as a long-lived stream and returns immediately.
// The previous handler blocked here for the whole life of the connection,
// which stopped loop() -- and therefore maintainWiFi() and CAN ingest -- for
// as long as a client was watching.
void handleEvents() {
  if (sseClientActive) {
    // Newest client wins; the old socket closes when this reference drops.
    sseDroppedClients++;
    closeSseClient();
  }

  sseClient = http.client();
  sseClient.setNoDelay(true);
  sseClient.println("HTTP/1.1 200 OK");
  sseClient.println("Content-Type: text/event-stream");
  sseClient.println("Cache-Control: no-cache");
  sseClient.println("Connection: keep-alive");
  sseClient.println("Access-Control-Allow-Origin: *");
  sseClient.println();

  sseClientActive = true;
  sseLastSendMs = 0;
  sseLastAcceptedMs = millis();
  // Do NOT call client.stop() here. WebServer releases its WiFiClient by
  // assigning an empty one (refcount drop), which leaves this copy alive.
}

void maintainSseClient() {
  if (!sseClientActive) return;

  if (!sseClient.connected()) {
    closeSseClient();
    return;
  }

  if (millis() - sseLastSendMs < TELEMETRY_INTERVAL_MS) return;
  sseLastSendMs = millis();

  String packet = buildTelemetryPacket();
  const size_t framed = packet.length() + 8;  // "data: " + packet + "\n\n"
  if (framed > SSE_FRAME_BUF_MAX) {
    // Oversized packet would force multi-write; skip rather than block.
    noteSseSkipOrStall();
    return;
  }

  if (SSE_BACKPRESSURE_CHECK_ENABLED && !sseSocketWritable()) {
    // Telemetry is latest-wins: drop this sample instead of freezing firmware.
    noteSseSkipOrStall();
    return;
  }

  char frame[SSE_FRAME_BUF_MAX];
  memcpy(frame, "data: ", 6);
  memcpy(frame + 6, packet.c_str(), packet.length());
  frame[6 + packet.length()] = '\n';
  frame[7 + packet.length()] = '\n';

  const int sock = sseClient.fd();
  if (sock < 0) {
    sseDroppedClients++;
    closeSseClient();
    return;
  }

  // Bypass WiFiClient::write()'s 1 s × 10 select retry path entirely.
  const int sent = ::send(sock, frame, framed, MSG_DONTWAIT);
  if (sent < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      noteSseSkipOrStall();
      return;
    }
    sseDroppedClients++;
    closeSseClient();
    return;
  }
  if (static_cast<size_t>(sent) < framed) {
    // Partial SSE frame corrupts the stream; force the phone to reconnect.
    sseDroppedClients++;
    closeSseClient();
    return;
  }

  if (SSE_CLIENT_FLUSH_ENABLED) {
    sseClient.flush();
  }
  sseLastAcceptedMs = millis();
}

void setupFilesystem() {
  fsReady = LittleFS.begin(true);
  Serial.print("LittleFS: ");
  Serial.println(fsReady ? "mounted" : "mount failed");
  if (fsReady) {
    Serial.print("Dashboard file: ");
    Serial.println(LittleFS.exists("/index.html") ? "present" : "missing");
  }
}

void setupHttp() {
  http.on("/", handleRoot);
  http.on("/index.html", handleRoot);
  http.on("/test", handleTestPage);
  http.on("/events", handleEvents);
  http.on("/telemetry.json", handleTelemetryJson);
  http.on("/canlog.json", handleCanLogJson);
  http.on("/odometer/status", handleOdometerStatus);
  http.on("/odometer/set", handleOdometerSet);
  http.on("/trip/status", handleTripStatus);
  http.on("/trip/reset", handleTripReset);
  http.on("/capture", handleCapturePage);
  http.on("/capture/status", handleCaptureStatus);
  http.on("/capture/start", handleCaptureStart);
  http.on("/capture/mark", handleCaptureMark);
  http.on("/capture/stop", handleCaptureStop);
  http.on("/capture/download", handleCaptureDownload);
  http.on("/capture/probe", handleCaptureProbe);
  http.on("/correlate", handleCorrelationPage);
  http.on("/correlate/status", handleCorrelationStatus);
  http.on("/correlate/start", handleCorrelationStart);
  http.on("/correlate/mark", handleCorrelationMark);
  http.on("/correlate/stop", handleCorrelationStop);
  http.on("/correlate/download", handleCorrelationDownload);
  http.on("/obd-rpm-test", handleObdRpmTest);
  http.on("/obd-log-test", handleObdLogTest);
  http.on("/health", handleHealth);
  http.on("/manifest.webmanifest", []() {
    if (!streamFsFile("/manifest.webmanifest", "application/manifest+json")) {
      http.send(404, "text/plain", "manifest missing");
    }
  });
  http.on("/icon.svg", []() {
    if (!streamFsFile("/icon.svg", "image/svg+xml")) {
      http.send(404, "text/plain", "icon missing");
    }
  });
  http.on("/apple-touch-icon.svg", []() {
    if (!streamFsFile("/icon.svg", "image/svg+xml")) {
      http.send(404, "text/plain", "icon missing");
    }
  });
  http.onNotFound([]() {
    http.send(404, "text/plain", "not found");
  });
  http.begin();
  Serial.println("Dashboard: http://192.168.4.1");
  Serial.println("Simple test page: http://192.168.4.1/test");
  Serial.println("Odometer status: http://192.168.4.1/odometer/status");
  Serial.println("Trip status: http://192.168.4.1/trip/status");
  Serial.println("Passive capture page: http://192.168.4.1/capture");
  Serial.println("Passive + OBD correlation page: http://192.168.4.1/correlate");
}

void setupCan() {
  printWiringSummary();
  if (!can.begin()) {
    Serial.println("MCP2515 not detected over SPI. Check VCC/GND/SCK/SI/SO/CS wiring.");
    canReady = false;
    return;
  }

  if (!can.configure(CAN_LISTEN_ONLY)) {
    Serial.println("MCP2515 configuration failed.");
    canReady = false;
    return;
  }

  canReady = true;
  Serial.printf("MCP2515 started: %u MHz crystal, %lu bit/s, SPI=%lu Hz, filters=%s, mode=%s\n",
                MCP_CLOCK_MHZ,
                static_cast<unsigned long>(CAN_BITRATE),
                static_cast<unsigned long>(MCP_SPI_HZ),
                MCP_FILTER_IMPORTANT_IDS_ONLY ? "important-decoded-ids" : "accept-all",
                CAN_LISTEN_ONLY ? "listen-only" : "normal OBD read-only requests");
}

void setup() {
  Serial.begin(115200);
  delay(1200);

  Serial.println();
  Serial.println("Dominar 400 ESP32-S3 MCP2515 bridge booting...");
  setupFilesystem();
  setupOdometer();
  setupTrips();
  setupWiFi();
  setupHttp();

  if (WIFI_MOCK_TELEMETRY_ENABLED) {
    Serial.println("Wi-Fi mock telemetry mode enabled. CAN is not used in this build.");
  } else {
    setupCan();
  }
}

void loop() {
  static uint32_t lastPidPollMs = 0;
  static uint32_t lastTelemetryMs = 0;

  http.handleClient();
  maintainSseClient();

  if (WIFI_MOCK_TELEMETRY_ENABLED) {
    updateMockTelemetry();
  }

  if (canReady && CAN_OBD_REQUESTS_ENABLED && millis() - lastPidPollMs >= PID_INTERVAL_MS) {
    pollOnePid();
    lastPidPollMs = millis();
  }

  processPassiveCanFrames();
  maintainOdometer();
  maintainTripComputer();
  maintainCapture();
  maintainCorrelation();

  if (millis() - lastTelemetryMs >= TELEMETRY_INTERVAL_MS) {
    sendTelemetry();
    lastTelemetryMs = millis();
  }
}
