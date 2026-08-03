#pragma once

#include "can_types.h"

class Mcp2515 {
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
  static const uint8_t RESET = 0xC0;
  static const uint8_t READ = 0x03;
  static const uint8_t WRITE = 0x02;
  static const uint8_t BIT_MODIFY = 0x05;
  static const uint8_t READ_STATUS = 0xA0;
  static const uint8_t RTS_TXB0 = 0x81;

  static const uint8_t CANSTAT = 0x0E;
  static const uint8_t CANCTRL = 0x0F;
  static const uint8_t CNF3 = 0x28;
  static const uint8_t CNF2 = 0x29;
  static const uint8_t CNF1 = 0x2A;
  static const uint8_t CANINTE = 0x2B;
  static const uint8_t CANINTF = 0x2C;
  static const uint8_t EFLG = 0x2D;

  static const uint8_t RXF0SIDH = 0x00;
  static const uint8_t RXF1SIDH = 0x04;
  static const uint8_t RXF2SIDH = 0x08;
  static const uint8_t RXF3SIDH = 0x10;
  static const uint8_t RXF4SIDH = 0x14;
  static const uint8_t RXF5SIDH = 0x18;
  static const uint8_t RXM0SIDH = 0x20;
  static const uint8_t RXM1SIDH = 0x24;

  static const uint8_t TXB0CTRL = 0x30;
  static const uint8_t TXB0SIDH = 0x31;
  static const uint8_t TXB0SIDL = 0x32;
  static const uint8_t TXB0EID8 = 0x33;
  static const uint8_t TXB0EID0 = 0x34;
  static const uint8_t TXB0DLC = 0x35;
  static const uint8_t TXB0D0 = 0x36;

  static const uint8_t RXB0CTRL = 0x60;
  static const uint8_t RXB0SIDH = 0x61;
  static const uint8_t RXB1CTRL = 0x70;
  static const uint8_t RXB1SIDH = 0x71;

  static const uint8_t RX0IF = 0x01;
  static const uint8_t RX1IF = 0x02;
  static const uint8_t RX0OVR = 0x40;
  static const uint8_t RX1OVR = 0x80;
  static const uint8_t TXREQ = 0x08;
  static const uint8_t ABAT = 0x10;

  static const uint8_t MODE_MASK = 0xE0;
  static const uint8_t MODE_NORMAL = 0x00;
  static const uint8_t MODE_LISTEN = 0x60;
  static const uint8_t MODE_CONFIG = 0x80;

  uint32_t rxFrames_ = 0;
  uint32_t txRequests_ = 0;

  void select();
  void deselect();
  void command(uint8_t instruction);
  void reset();
  uint8_t readRegister(uint8_t address);
  void writeRegister(uint8_t address, uint8_t value);
  void bitModify(uint8_t address, uint8_t mask, uint8_t value);
  void writeStandardIdRegisters(uint8_t base, uint16_t id);
  void configureImportantReceiveFilters();
  bool setMode(uint8_t mode);
  void abortPendingTx();
  void readRxBuffer(uint8_t base, CanFrame& frame);
};

extern Mcp2515 gCan;
