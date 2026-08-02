#include "telemetry_format.h"

#include <math.h>
#include <stdio.h>

#include "can_ingest.h"
#include "d400_config.h"
#include "mcp2515.h"
#include "passive_decode.h"
#include "trip_computer.h"

size_t formatHealthJson(char* buf, size_t cap) {
  uint32_t now = millis();
  uint32_t lastCanAge = passiveLastCanFrameMs() == 0 ? 0 : now - passiveLastCanFrameMs();

  int n = snprintf(buf, cap,
                   "{\"ms\":%lu,\"can_ready\":%s,\"can_bitrate\":%lu,"
                   "\"mcp_spi_hz\":%lu,\"rx_frames\":%lu,\"dropped_corrupt_frames\":%lu,"
                   "\"mcp_rx_overflows\":%lu,\"mcp_reinit_attempts\":%lu,"
                   "\"last_can_age_ms\":%lu,\"link_quality_pct\":%u,"
                   "\"odometer_m\":%lu,\"odometer_save_count\":%lu,"
                   "\"trip_prefs_ready\":%s,\"transport\":\"binary\"}",
                   static_cast<unsigned long>(now),
                   gCanReady ? "true" : "false",
                   static_cast<unsigned long>(D400_CAN_BITRATE),
                   static_cast<unsigned long>(D400_MCP_SPI_HZ),
                   static_cast<unsigned long>(gCan.rxFrameCount()),
                   static_cast<unsigned long>(gDroppedCorruptFrames),
                   static_cast<unsigned long>(gMcpRxOverflowEvents),
                   static_cast<unsigned long>(gMcpReinitAttempts),
                   static_cast<unsigned long>(lastCanAge),
                   static_cast<unsigned>(lastCanAge < 200 ? 100 : lastCanAge < 500 ? 75 :
                                                              lastCanAge < 1000 ? 35 : 0),
                   static_cast<unsigned long>(odometerMetersValue()),
                   static_cast<unsigned long>(odometerSaveCountValue()),
                   gOdometerPrefsReady ? "true" : "false");
  return n > 0 ? static_cast<size_t>(n) : 0;
}

extern uint32_t gBenchCanDrainUs;
extern uint32_t gBenchPackUs;
extern uint32_t gBenchSseSendUs;
extern uint32_t gBenchLoopUsMax;
extern uint32_t gBenchSseSkippedDelta;

size_t formatBenchStatusJson(char* buf, size_t cap) {
  int n = snprintf(buf, cap,
                   "{\"ms\":%lu,\"can_drain_us\":%lu,\"pack_us\":%lu,"
                   "\"sse_send_us\":%lu,\"loop_us_max\":%lu,"
                   "\"sse_skipped_delta\":%lu,\"transport\":\"binary\"}",
                   static_cast<unsigned long>(millis()),
                   static_cast<unsigned long>(gBenchCanDrainUs),
                   static_cast<unsigned long>(gBenchPackUs),
                   static_cast<unsigned long>(gBenchSseSendUs),
                   static_cast<unsigned long>(gBenchLoopUsMax),
                   static_cast<unsigned long>(gBenchSseSkippedDelta));
  return n > 0 ? static_cast<size_t>(n) : 0;
}

void fillRideTelemetryBinary(RideTelemetryBinary& out, const TelemetryPublishContext& ctx) {
  out.magic = D400_BINARY_MAGIC;
  out.version = D400_BINARY_VERSION;
  out.seq = static_cast<uint16_t>(ctx.seq & 0xFFFF);
  out.ms = ctx.ms;
  out.rpm = isnan(gTelemetry.rpm) ? 0.0f : gTelemetry.rpm;
  out.speed_kph = isnan(gTelemetry.speed) ? 0.0f : gTelemetry.speed;
  out.gear = gDisplayGear[0];
  out.gear_pad = 0;
  out.odometer_km = odometerKm();
  out.engine_temp_c = isnan(gTelemetry.coolant) ? 0.0f : gTelemetry.coolant;
  out.tps_pct = isnan(gTelemetry.tps) ? 0.0f : gTelemetry.tps;
  out.map_kpa = isnan(gTelemetry.map) ? 0.0f : gTelemetry.map;
  out.iat_c = isnan(gTelemetry.iat) ? 0.0f : gTelemetry.iat;
  out.battery_v = isnan(gTelemetry.vbatt) ? 0.0f : gTelemetry.vbatt;
  out.trip1_distance_km = tripDistanceKm(gTrips[0]);
  out.trip1_seconds = gTrips[0].seconds;
  out.trip1_kmpl = tripKmpl(gTrips[0]);
  out.trip2_distance_km = tripDistanceKm(gTrips[1]);
  out.trip2_seconds = gTrips[1].seconds;
  out.trip2_kmpl = tripKmpl(gTrips[1]);
  out.sse_skipped = ctx.sseSkipped;
  out.sse_dropped = ctx.sseDropped;
  out.softap_stations = ctx.softapStations;
  out.reserved[0] = out.reserved[1] = out.reserved[2] = 0;
}

size_t formatRideTelemetryHex(char* buf, size_t cap, const RideTelemetryBinary& payload) {
  if (cap < D400_BINARY_HEX_LINE_MAX) return 0;

  int n = snprintf(buf, cap, "binhex:");
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&payload);
  for (size_t i = 0; i < sizeof(payload) && n < static_cast<int>(cap - 3); i++) {
    n += snprintf(buf + n, cap - static_cast<size_t>(n), "%02X", bytes[i]);
  }
  return n > 0 ? static_cast<size_t>(n) : 0;
}
