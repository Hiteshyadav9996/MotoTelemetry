#pragma once

#include <Arduino.h>

// Dominar 400 ESP32-S3 + MCP2515 shared configuration.

static const char* D400_AP_SSID = "D400Telemetry";
static const char* D400_AP_PASS = "dominar400";
static const char* D400_MDNS_HOSTNAME = "d400telemetry";

static const int D400_SPI_SCK_PIN = 12;
static const int D400_SPI_MISO_PIN = 13;
static const int D400_SPI_MOSI_PIN = 11;
static const int D400_CAN_CS_PIN = 10;
static const int D400_CAN_INT_PIN = 9;

static const uint8_t D400_MCP_CLOCK_MHZ = 8;
static const uint32_t D400_MCP_SPI_HZ = 8000000UL;
static const uint32_t D400_CAN_BITRATE = 500000;
static const bool D400_CAN_LISTEN_ONLY = true;
static const bool D400_MCP_FILTER_IMPORTANT_IDS_ONLY = true;
static const bool D400_DROP_EXTENDED_FRAMES = true;

static const uint32_t D400_TELEMETRY_INTERVAL_MS = 50;
static const uint8_t D400_CAN_DRAIN_LIMIT = 192;
static const uint32_t D400_CAN_STALE_REINIT_MS = 2000;
static const uint32_t D400_CAN_REINIT_COOLDOWN_MS = 3000;

static const bool D400_SSE_BACKPRESSURE_CHECK = true;
static const uint32_t D400_SSE_STALL_TIMEOUT_MS = 4000;
static const size_t D400_SSE_FRAME_BUF_MAX = 256;
static const size_t D400_RIDE_TELEMETRY_BINARY_SIZE = 78;
static const size_t D400_BINARY_HEX_LINE_MAX = 168;  // "binhex:" + 78*2 + NUL

static const uint32_t D400_ODOMETER_INITIAL_METERS = 53988UL * 1000UL;
static const uint32_t D400_ODOMETER_SAVE_DISTANCE_METERS = 100;
static const uint32_t D400_ODOMETER_SAVE_INTERVAL_MS = 30000;
static const uint32_t D400_ODOMETER_SPEED_MAX_AGE_MS = 500;
static const uint32_t D400_ODOMETER_MAX_INTEGRATION_GAP_MS = 1000;
static const float D400_ODOMETER_MIN_SPEED_KPH = 1.0f;
static const char* D400_PREF_NAMESPACE = "d400";
static const char* D400_ODOMETER_PREF_METERS_KEY = "odo_m";

static const uint8_t D400_TRIP_COUNT = 2;
static const uint32_t D400_TRIP_TICK_MS = 1000;
static const uint32_t D400_TRIP_SAVE_DISTANCE_METERS = 100;
static const uint32_t D400_TRIP_SAVE_INTERVAL_MS = 30000;
static const uint32_t D400_TRIP_SPEED_MAX_AGE_MS = 500;
static const uint32_t D400_TRIP_RPM_MAX_AGE_MS = 500;
static const uint32_t D400_TRIP_SENSOR_MAX_AGE_MS = 1500;
static const float D400_TRIP_ENGINE_RUNNING_RPM = 500.0f;
static const float D400_TRIP_DISPLACEMENT_M3 = 0.0003733f;
static const float D400_TRIP_GAS_CONSTANT_R = 287.05f;
static const float D400_TRIP_FUEL_DENSITY_G_L = 740.0f;
static const float D400_TRIP_STOICH_AFR = 14.7f;
static const float D400_TRIP_VE_BASE = 0.60f;
static const float D400_TRIP_VE_TPS_SCALE = 0.25f;

static const float D400_PASSIVE_TPS_IDLE_OBD_PCT = 27.0f * 100.0f / 255.0f;
static const float D400_PASSIVE_TPS_ABS_SCALE =
    (100.0f - D400_PASSIVE_TPS_IDLE_OBD_PCT) / 255.0f;
static const float D400_PASSIVE_MAP_OFFSET_KPA = 1.0f;
static const float D400_PASSIVE_COOLANT_SCALE = 0.099314f;
static const float D400_PASSIVE_COOLANT_OFFSET = 2983.421676f;
static const float D400_PASSIVE_IAT_SCALE = 0.095760f;
static const float D400_PASSIVE_IAT_OFFSET = 34.038803f;
static const float D400_PASSIVE_301_TACH_RPM_SCALE = 40.0f;
static const float D400_PASSIVE_310_BUCKET_RPM_SCALE = 100.0f;
static const float D400_PASSIVE_30C_SPEED_KPH_SCALE = 118.0f;
static const float D400_PASSIVE_DISTANCE_CALIBRATION = 17.1f / 17.9f;
static const float D400_PASSIVE_303_BATTERY_V_SCALE = 0.1f;
static const uint32_t D400_PASSIVE_RPM_PAIR_MAX_AGE_MS = 160;

static const char* D400_FIRMWARE_VARIANT_RIDE = "ride-minimal-binary";

// Binary telemetry wire format (Path C — sole ride transport).
static const uint8_t D400_BINARY_MAGIC = 0x44;  // 'D'
static const uint8_t D400_BINARY_VERSION = 1;
