#pragma once

#include "can_types.h"
#include "twai_can.h"

extern bool gCanReady;
extern uint32_t gDroppedCorruptFrames;
extern uint32_t gCanRxOverflowEvents;
extern uint32_t gCanReinitAttempts;
extern uint32_t gLastCanRxOverflowMs;

void setupCanBridge();
void processCanFrames();
void maintainCanHealth();
void serviceCanRxOverflows();

bool isImportantFilteredStandardId(uint32_t id);
bool shouldDropCanFrame(const CanFrame& frame);
bool ingestCanFrame(const CanFrame& frame);

#ifdef D400_LAB_BUILD
void rememberCanFrame(const CanFrame& frame);
#endif
