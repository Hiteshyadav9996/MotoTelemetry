#pragma once

#include <Arduino.h>
#include <stdint.h>

extern uint32_t gBenchCanDrainUs;
extern uint32_t gBenchPackUs;
extern uint32_t gBenchSseSendUs;
extern uint32_t gBenchLoopUsMax;
extern uint32_t gBenchSseSkippedDelta;

class BenchScope {
 public:
  explicit BenchScope(uint32_t& target) : target_(target), start_(micros()) {}
  ~BenchScope() { target_ = micros() - start_; }

 private:
  uint32_t& target_;
  uint32_t start_;
};

void benchMarkLoopStart();
void benchMarkLoopEnd();
