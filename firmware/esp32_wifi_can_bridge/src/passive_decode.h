#pragma once

#include "can_types.h"

extern TelemetryValues gTelemetry;
extern char gDisplayGear[2];

bool applyPassiveCanFrame(const CanFrame& frame);
char estimateGearChar();

// Passive signal freshness accessors used by trip computer.
bool passiveRpmFresh(uint32_t now);
bool passiveSpeedFresh(uint32_t now);
bool passiveSensorFresh(uint32_t now);
float distanceSpeedKph(float displayedSpeedKph);

uint32_t passiveLastCanFrameMs();
uint32_t passiveLastGoodResponseMs();
