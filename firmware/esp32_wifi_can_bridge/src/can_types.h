#pragma once

#include <Arduino.h>

struct CanFrame {
  uint32_t id = 0;
  bool extended = false;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

struct TelemetryValues {
  float rpm = NAN;
  float coolant = NAN;
  float iat = NAN;
  float map = NAN;
  float tps = NAN;
  float tpsAbs = NAN;
  float speed = NAN;
  float vbatt = NAN;
};

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

#pragma pack(push, 1)
struct RideTelemetryBinary {
  uint8_t magic;
  uint8_t version;
  uint16_t seq;
  uint32_t ms;
  float rpm;
  float speed_kph;
  char gear;
  uint8_t gear_pad;
  float odometer_km;
  float engine_temp_c;
  float tps_pct;
  float map_kpa;
  float iat_c;
  float battery_v;
  float trip1_distance_km;
  uint32_t trip1_seconds;
  float trip1_kmpl;
  float trip2_distance_km;
  uint32_t trip2_seconds;
  float trip2_kmpl;
  uint32_t sse_skipped;
  uint32_t sse_dropped;
  uint8_t softap_stations;
  uint8_t reserved[3];
};

#pragma pack(pop)
