// Dominar 400 ESP32-S3 + MCP2515 Wi-Fi CAN telemetry bridge.
//
// Hardware target:
// - ESP32-S3-N16R8 dev board.
// - MCP2515 + TJA1050 CAN module wired over SPI.
// - MCP2515 VCC should be 3V3 when connected directly to ESP32 GPIO.
// - CANH/CANL go to the diagnostic adapter only after bench upload/testing.
//
// This firmware sends read-only OBD-II Mode 01 requests and broadcasts JSON
// telemetry over UDP to 192.168.4.255:4210.

#include <Arduino.h>
#include <LittleFS.h>
#include <SPI.h>
#include <WebServer.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <math.h>

static const char* AP_SSID = "D400Telemetry";
static const char* AP_PASS = "dominar400";
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
static const bool WIFI_MOCK_TELEMETRY_ENABLED = true;

// Most blue MCP2515 modules use an 8 MHz crystal. If SPI works but CAN never
// receives anything, check the crystal marking and try 16.
static const uint8_t MCP_CLOCK_MHZ = 8;
static const bool CAN_OBD_REQUESTS_ENABLED = !WIFI_MOCK_TELEMETRY_ENABLED;
static const bool CAN_LISTEN_ONLY = !CAN_OBD_REQUESTS_ENABLED;
static const uint32_t CAN_BITRATE = 500000;
static const uint32_t PID_TIMEOUT_MS = 35;
static const uint32_t TELEMETRY_INTERVAL_MS = 50;
static const uint32_t PID_INTERVAL_MS = 15;

WiFiUDP udp;
WebServer http(80);
uint32_t seqNo = 0;
uint32_t txRequests = 0;
uint32_t rxFrames = 0;
uint32_t rxResponses = 0;
uint32_t pidTimeouts = 0;
uint32_t lastGoodResponseMs = 0;
bool canReady = false;
bool fsReady = false;

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
  float speed = NAN;
  float vbatt = NAN;
};

Telemetry telemetry;

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

class Mcp2515 {
 public:
  bool begin() {
    pinMode(CAN_CS_PIN, OUTPUT);
    digitalWrite(CAN_CS_PIN, HIGH);
    pinMode(CAN_INT_PIN, INPUT_PULLUP);

    SPI.begin(SPI_SCK_PIN, SPI_MISO_PIN, SPI_MOSI_PIN, CAN_CS_PIN);
    SPI.setFrequency(4000000);

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

    // Accept all valid standard/extended frames while discovering the bike.
    writeRegister(RXB0CTRL, 0x64);  // receive any, rollover to RXB1
    writeRegister(RXB1CTRL, 0x60);  // receive any
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
    uint8_t sidH = readRegister(base);
    uint8_t sidL = readRegister(base + 1);
    uint8_t eid8 = readRegister(base + 2);
    uint8_t eid0 = readRegister(base + 3);
    uint8_t dlc = readRegister(base + 4) & 0x0F;

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
      frame.data[i] = readRegister(base + 5 + i);
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

String estimatedGear() {
  if (isnan(telemetry.speed) || telemetry.speed < 3) return "N";
  if (telemetry.speed < 23) return "1";
  if (telemetry.speed < 43) return "2";
  if (telemetry.speed < 68) return "3";
  if (telemetry.speed < 94) return "4";
  if (telemetry.speed < 125) return "5";
  return "6";
}

uint8_t linkQuality() {
  if (WIFI_MOCK_TELEMETRY_ENABLED) return 100;
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
  telemetry.vbatt = 14.12f + 0.08f * sinf(t * 0.9f);
}

String buildTelemetryPacket() {
  String packet;
  packet.reserve(520);
  packet += "{\"seq\":";
  packet += String(++seqNo);
  packet += ",\"ms\":";
  packet += String(millis());

  appendFloat(packet, "rpm", telemetry.rpm, 1);
  appendFloat(packet, "speed_kph", telemetry.speed, 1);
  appendFloat(packet, "speed", telemetry.speed, 1);
  packet += ",\"gear\":\"";
  packet += estimatedGear();
  packet += "\"";
  appendFloat(packet, "coolant_c", telemetry.coolant, 1);
  appendFloat(packet, "coolant", telemetry.coolant, 1);
  appendFloat(packet, "engine_temp_c", telemetry.coolant, 1);
  appendFloat(packet, "iat_c", telemetry.iat, 1);
  appendFloat(packet, "iat", telemetry.iat, 1);
  appendFloat(packet, "map_kpa", telemetry.map, 1);
  appendFloat(packet, "map", telemetry.map, 1);
  appendFloat(packet, "tps_pct", telemetry.tps, 1);
  appendFloat(packet, "tps", telemetry.tps, 1);
  appendFloat(packet, "battery_v", telemetry.vbatt, 2);
  appendFloat(packet, "vbatt", telemetry.vbatt, 2);

  packet += ",\"source\":\"";
  packet += WIFI_MOCK_TELEMETRY_ENABLED ? "esp32-mock" : "mcp2515-obd";
  packet += "\"";
  packet += ",\"can_ready\":";
  packet += canReady ? "true" : "false";
  packet += ",\"can_bitrate\":";
  packet += String(CAN_BITRATE);
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
  packet += "}";

  return packet;
}

void sendTelemetry() {
  String packet = buildTelemetryPacket();

  udp.beginPacket(UDP_BROADCAST, UDP_PORT);
  udp.write(reinterpret_cast<const uint8_t*>(packet.c_str()), packet.length());
  udp.endPacket();

  static uint32_t lastSerialPrintMs = 0;
  if (millis() - lastSerialPrintMs >= 500) {
    Serial.println(packet);
    lastSerialPrintMs = millis();
  }
}

void drainCanQueue() {
  CanFrame frame;
  while (can.readFrame(frame)) {
    // Drop stale frames before an OBD request so the response matching is clean.
  }
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

  if (!can.sendFrame(tx)) return false;

  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    CanFrame rx;
    if (!can.readFrame(rx)) {
      delay(1);
      continue;
    }

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
    return true;
  }

  pidTimeouts++;
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
    case 0x11:
      telemetry.tps = static_cast<float>(b[0]) * 100.0f / 255.0f;
      break;
    case 0x0D:
      telemetry.speed = static_cast<float>(b[0]);
      break;
    case 0x42:
      telemetry.vbatt = ((static_cast<uint16_t>(b[0]) * 256) + b[1]) / 1000.0f;
      break;
  }
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

void setupWiFi() {
  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  udp.begin(UDP_PORT);

  Serial.print("Wi-Fi AP: ");
  Serial.println(AP_SSID);
  Serial.print("Password: ");
  Serial.println(AP_PASS);
  Serial.print("AP IP: ");
  Serial.println(WiFi.softAPIP());
  Serial.printf("UDP telemetry broadcast: %s:%u\n",
                UDP_BROADCAST.toString().c_str(), UDP_PORT);
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
  }
  http.sendHeader("Cache-Control", "no-store");
  http.send(200, "application/json", buildTelemetryPacket());
}

void handleHealth() {
  http.send(200, "text/plain", WIFI_MOCK_TELEMETRY_ENABLED ? "esp32 mock telemetry ok" : "esp32 can bridge ok");
}

void handleEvents() {
  WiFiClient client = http.client();
  client.setNoDelay(true);
  client.println("HTTP/1.1 200 OK");
  client.println("Content-Type: text/event-stream");
  client.println("Cache-Control: no-cache");
  client.println("Connection: keep-alive");
  client.println("Access-Control-Allow-Origin: *");
  client.println();

  uint32_t lastSendMs = 0;
  while (client.connected()) {
    if (millis() - lastSendMs >= TELEMETRY_INTERVAL_MS) {
      if (WIFI_MOCK_TELEMETRY_ENABLED) {
        updateMockTelemetry();
      }
      String packet = buildTelemetryPacket();
      client.print("data: ");
      client.print(packet);
      client.print("\n\n");
      client.flush();
      lastSendMs = millis();
    }
    delay(2);
    yield();
  }
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
  Serial.printf("MCP2515 started: %u MHz crystal, %lu bit/s, mode=%s\n",
                MCP_CLOCK_MHZ,
                static_cast<unsigned long>(CAN_BITRATE),
                CAN_LISTEN_ONLY ? "listen-only" : "normal OBD read-only requests");
}

void setup() {
  Serial.begin(115200);
  delay(1200);

  Serial.println();
  Serial.println("Dominar 400 ESP32-S3 MCP2515 bridge booting...");
  setupFilesystem();
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

  if (WIFI_MOCK_TELEMETRY_ENABLED) {
    updateMockTelemetry();
  }

  if (canReady && CAN_OBD_REQUESTS_ENABLED && millis() - lastPidPollMs >= PID_INTERVAL_MS) {
    pollOnePid();
    lastPidPollMs = millis();
  }

  if (canReady && CAN_LISTEN_ONLY) {
    CanFrame frame;
    while (can.readFrame(frame)) {
      if ((rxFrames % 100) == 0) {
        Serial.printf("RX id=0x%lX dlc=%u ext=%u\n",
                      static_cast<unsigned long>(frame.id), frame.dlc, frame.extended ? 1 : 0);
      }
    }
  }

  if (millis() - lastTelemetryMs >= TELEMETRY_INTERVAL_MS) {
    sendTelemetry();
    lastTelemetryMs = millis();
  }
}
