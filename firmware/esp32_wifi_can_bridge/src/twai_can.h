#pragma once

#include "can_types.h"

class TwaiCan {
 public:
  bool begin();
  bool configure(bool listenOnly);
  bool sendFrame(const CanFrame& frame);
  bool readFrame(CanFrame& frame);
  uint8_t errorFlags();
  uint8_t rxOverflowFlags();
  void clearRxOverflowFlags();
  uint8_t status();

  uint32_t rxFrameCount() const { return rxFrames_; }
  uint32_t txRequestCount() const { return txRequests_; }

 private:
  uint32_t rxFrames_ = 0;
  uint32_t txRequests_ = 0;
  uint8_t overflowLatched_ = 0;
  bool installed_ = false;

  void stopAndUninstall();
};

extern TwaiCan gCan;
