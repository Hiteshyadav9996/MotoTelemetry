#include "bench_metrics.h"

uint32_t gBenchCanDrainUs = 0;
uint32_t gBenchPackUs = 0;
uint32_t gBenchSseSendUs = 0;
uint32_t gBenchLoopUsMax = 0;
uint32_t gBenchSseSkippedDelta = 0;

static uint32_t loopStartUs = 0;

void benchMarkLoopStart() {
  loopStartUs = micros();
}

void benchMarkLoopEnd() {
  uint32_t elapsed = micros() - loopStartUs;
  if (elapsed > gBenchLoopUsMax) gBenchLoopUsMax = elapsed;
}
