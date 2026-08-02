#pragma once

#include "can_types.h"
#include "mcp2515.h"

extern bool gCanReady;
extern uint32_t gDroppedCorruptFrames;
extern uint32_t gMcpRxOverflowEvents;
extern uint32_t gMcpReinitAttempts;
extern uint32_t gLastMcpRxOverflowMs;

void setupCanBridge();
void processCanFrames();
void maintainCanHealth();
void serviceMcpRxOverflows();

bool isImportantFilteredStandardId(uint32_t id);
bool shouldDropCanFrame(const CanFrame& frame);
bool ingestCanFrame(const CanFrame& frame);

#ifdef D400_LAB_BUILD
void rememberCanFrame(const CanFrame& frame);
#endif
