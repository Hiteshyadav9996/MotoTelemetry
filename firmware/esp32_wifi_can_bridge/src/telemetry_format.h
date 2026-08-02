#pragma once

#include <stddef.h>
#include <stdint.h>

#include "can_types.h"

struct TelemetryPublishContext {
  uint32_t seq;
  uint32_t ms;
  uint32_t sseSkipped;
  uint32_t sseDropped;
  uint8_t softapStations;
};

size_t formatHealthJson(char* buf, size_t cap);
size_t formatBenchStatusJson(char* buf, size_t cap);

void fillRideTelemetryBinary(RideTelemetryBinary& out, const TelemetryPublishContext& ctx);
size_t formatRideTelemetryHex(char* buf, size_t cap, const RideTelemetryBinary& payload);
