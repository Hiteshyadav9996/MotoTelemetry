#include "passive_decode.h"

#include "d400_config.h"

TelemetryValues gTelemetry;
char gDisplayGear[2] = {'N', '\0'};

static bool hasPassiveRpm = false;
static uint32_t lastPassiveRpmMs = 0;

static bool hasPassive301Tach = false;
static uint8_t lastPassive301TachRaw = 0;
static uint32_t lastPassive301TachMs = 0;

static bool hasPassive302RpmCompanion = false;
static uint32_t lastPassive302RpmCompanionMs = 0;

static bool hasPassiveTps = false;
static uint32_t lastPassiveTpsMs = 0;

static bool hasPassiveCoolant = false;
static uint32_t lastPassiveCoolantMs = 0;

static bool hasPassiveIat = false;
static uint32_t lastPassiveIatMs = 0;

static bool hasPassiveMap = false;
static uint32_t lastPassiveMapMs = 0;

static bool hasPassiveGear = false;
static uint8_t lastPassiveGearRaw = 0xFF;
static uint32_t lastPassiveGearMs = 0;

static bool hasPassiveSpeed = false;
static uint32_t lastPassiveSpeedMs = 0;

static bool hasPassiveBattery = false;
static uint32_t lastPassiveBatteryMs = 0;

static uint32_t lastCanFrameMs = 0;
static uint32_t lastGoodResponseMs = 0;

static float passiveTpsGripPct(uint8_t raw) {
  return static_cast<float>(raw) * 100.0f / 255.0f;
}

static float passiveTpsAbsPct(uint8_t raw) {
  float value = D400_PASSIVE_TPS_IDLE_OBD_PCT + static_cast<float>(raw) * D400_PASSIVE_TPS_ABS_SCALE;
  return constrain(value, D400_PASSIVE_TPS_IDLE_OBD_PCT, 100.0f);
}

static float passiveCoolantC(int16_t raw) {
  return D400_PASSIVE_COOLANT_SCALE * static_cast<float>(raw) + D400_PASSIVE_COOLANT_OFFSET;
}

static float passiveIatC(uint8_t raw) {
  return D400_PASSIVE_IAT_SCALE * static_cast<float>(raw) + D400_PASSIVE_IAT_OFFSET;
}

static float passiveMapKpa(uint8_t raw) {
  return static_cast<float>(raw) + D400_PASSIVE_MAP_OFFSET_KPA;
}

static void publishPassiveRpm(uint32_t frameId, uint16_t rawRpm, uint32_t now, float rpm) {
  (void)frameId;
  (void)rawRpm;
  hasPassiveRpm = true;
  lastPassiveRpmMs = now;
  gTelemetry.rpm = rpm;
  lastGoodResponseMs = now;
}

static bool publishPassive301TachIfPaired(uint32_t now) {
  if (!hasPassive301Tach || !hasPassive302RpmCompanion) return false;
  if (now - lastPassive301TachMs > D400_PASSIVE_RPM_PAIR_MAX_AGE_MS) return false;
  if (now - lastPassive302RpmCompanionMs > D400_PASSIVE_RPM_PAIR_MAX_AGE_MS) return false;

  publishPassiveRpm(0x301, lastPassive301TachRaw, now,
                    static_cast<float>(lastPassive301TachRaw) * D400_PASSIVE_301_TACH_RPM_SCALE);
  return true;
}

static bool isPassiveRpmOffValue(uint16_t rawRpm) {
  return rawRpm == 0xBFFD || rawRpm == 0xBFFE || rawRpm == 0xBFFF || rawRpm == 0xFFFF;
}

static bool isPassiveRpmOffFrame(const CanFrame& frame, uint16_t rawRpm) {
  if (isPassiveRpmOffValue(rawRpm)) return true;
  if (rawRpm != 0x287C) return false;
  if (frame.id == 0x312) {
    return frame.data[0] == 0x40 && frame.data[1] == 0x00 && frame.data[6] == 0x30;
  }
  if (frame.id == 0x313) {
    return frame.data[0] == 0x00 && frame.data[1] == 0x00 && frame.data[6] == 0x00;
  }
  return false;
}

static void updateDisplayGear(uint32_t now) {
  if (hasPassiveGear && now - lastPassiveGearMs <= 2000) {
    switch (lastPassiveGearRaw) {
      case 0: gDisplayGear[0] = 'N'; return;
      case 1: gDisplayGear[0] = '1'; return;
      case 2: gDisplayGear[0] = '2'; return;
      case 3: gDisplayGear[0] = '3'; return;
      case 4: gDisplayGear[0] = '4'; return;
      case 5: gDisplayGear[0] = '5'; return;
      case 6: gDisplayGear[0] = '6'; return;
      default: break;
    }
  }

  if (isnan(gTelemetry.speed) || gTelemetry.speed < 3) {
    gDisplayGear[0] = 'N';
  } else if (gTelemetry.speed < 23) {
    gDisplayGear[0] = '1';
  } else if (gTelemetry.speed < 43) {
    gDisplayGear[0] = '2';
  } else if (gTelemetry.speed < 68) {
    gDisplayGear[0] = '3';
  } else if (gTelemetry.speed < 94) {
    gDisplayGear[0] = '4';
  } else if (gTelemetry.speed < 125) {
    gDisplayGear[0] = '5';
  } else {
    gDisplayGear[0] = '6';
  }
}

uint32_t passiveLastCanFrameMs() {
  return lastCanFrameMs;
}

uint32_t passiveLastGoodResponseMs() {
  return lastGoodResponseMs;
}

float distanceSpeedKph(float displayedSpeedKph) {
  return hasPassiveSpeed ? displayedSpeedKph * D400_PASSIVE_DISTANCE_CALIBRATION : displayedSpeedKph;
}

bool passiveRpmFresh(uint32_t now) {
  return hasPassiveRpm && !isnan(gTelemetry.rpm) && now - lastPassiveRpmMs <= D400_TRIP_RPM_MAX_AGE_MS;
}

bool passiveSpeedFresh(uint32_t now) {
  return hasPassiveSpeed && !isnan(gTelemetry.speed) &&
         now - lastPassiveSpeedMs <= D400_TRIP_SPEED_MAX_AGE_MS;
}

bool passiveSensorFresh(uint32_t now) {
  return hasPassiveTps && hasPassiveIat && hasPassiveMap &&
         !isnan(gTelemetry.tps) && !isnan(gTelemetry.iat) && !isnan(gTelemetry.map) &&
         now - lastPassiveTpsMs <= D400_TRIP_SENSOR_MAX_AGE_MS &&
         now - lastPassiveIatMs <= D400_TRIP_SENSOR_MAX_AGE_MS &&
         now - lastPassiveMapMs <= D400_TRIP_SENSOR_MAX_AGE_MS;
}

char estimateGearChar() {
  return gDisplayGear[0];
}

bool applyPassiveCanFrame(const CanFrame& frame) {
  if (frame.extended) return false;

  uint32_t now = millis();
  lastCanFrameMs = now;

  if (frame.id == 0x301 && frame.dlc >= 3) {
    uint8_t rawTps = frame.data[2];
    hasPassiveTps = true;
    lastPassiveTpsMs = now;
    gTelemetry.tps = passiveTpsGripPct(rawTps);
    gTelemetry.tpsAbs = passiveTpsAbsPct(rawTps);

    lastPassive301TachRaw = frame.data[0];
    lastPassive301TachMs = now;
    hasPassive301Tach = true;
    publishPassiveRpm(0x301, lastPassive301TachRaw, now,
                      static_cast<float>(lastPassive301TachRaw) * D400_PASSIVE_301_TACH_RPM_SCALE);
    updateDisplayGear(now);
    return true;
  }

  if (frame.id == 0x302 && frame.dlc >= 7) {
    int16_t coolantRaw = static_cast<int16_t>((static_cast<uint16_t>(frame.data[0]) << 8) |
                                              frame.data[1]);
    hasPassiveCoolant = true;
    lastPassiveCoolantMs = now;
    gTelemetry.coolant = passiveCoolantC(coolantRaw);

    hasPassiveIat = true;
    lastPassiveIatMs = now;
    gTelemetry.iat = passiveIatC(frame.data[5]);

    hasPassiveMap = true;
    lastPassiveMapMs = now;
    gTelemetry.map = passiveMapKpa(frame.data[6]);

    if (frame.dlc >= 8) {
      lastPassive302RpmCompanionMs = now;
      hasPassive302RpmCompanion = true;
      if (publishPassive301TachIfPaired(now)) {
        updateDisplayGear(now);
        return true;
      }
    }
  }

  if (frame.id == 0x447 && frame.dlc >= 6 && frame.data[5] <= 6) {
    hasPassiveGear = true;
    lastPassiveGearRaw = frame.data[5];
    lastPassiveGearMs = now;
    updateDisplayGear(now);
  }

  if (frame.id == 0x30C && frame.dlc >= 2) {
    uint16_t rawSpeed = (static_cast<uint16_t>(frame.data[0]) << 8) | frame.data[1];
    hasPassiveSpeed = true;
    lastPassiveSpeedMs = now;
    gTelemetry.speed = static_cast<float>(rawSpeed) / D400_PASSIVE_30C_SPEED_KPH_SCALE;
    lastGoodResponseMs = now;
    updateDisplayGear(now);
  }

  if (frame.id == 0x303 && frame.dlc >= 2) {
    float volts = static_cast<float>(frame.data[1]) * D400_PASSIVE_303_BATTERY_V_SCALE;
    if (volts >= 9.0f && volts <= 16.5f) {
      hasPassiveBattery = true;
      lastPassiveBatteryMs = now;
      gTelemetry.vbatt = volts;
      lastGoodResponseMs = now;
    }
  }

  if (frame.dlc < 4) return false;

  if (frame.id == 0x310 && frame.dlc >= 6 && frame.data[4] == frame.data[5]) {
    uint16_t rawRpm = frame.data[4];
    if (!hasPassiveRpm || now - lastPassiveRpmMs > 250) {
      publishPassiveRpm(frame.id, rawRpm, now,
                        static_cast<float>(rawRpm) * D400_PASSIVE_310_BUCKET_RPM_SCALE);
      updateDisplayGear(now);
      return true;
    }
  }

  if (frame.id == 0x313 || frame.id == 0x312) {
    uint16_t rawRpm = (static_cast<uint16_t>(frame.data[2]) << 8) | frame.data[3];
    if (isPassiveRpmOffFrame(frame, rawRpm)) {
      publishPassiveRpm(frame.id, rawRpm, now, 0.0f);
      updateDisplayGear(now);
      return true;
    }
  }
  return false;
}
