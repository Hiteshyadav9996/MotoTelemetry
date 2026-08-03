#pragma once

#include <WebServer.h>

#include "can_types.h"
#include "telemetry_format.h"

void sseInit(WebServer& http);
void sseHandleEvents(WebServer& http);
void ssePublishBinary(const RideTelemetryBinary& payload);
void sseMaintain();

uint32_t sseSkippedFrames();
uint32_t sseDroppedClients();

const RideTelemetryBinary* sseCachedBinary();
