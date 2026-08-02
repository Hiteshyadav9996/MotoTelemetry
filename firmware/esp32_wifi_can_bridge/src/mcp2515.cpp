#include "mcp2515.h"

#include <SPI.h>

#include "d400_config.h"

Mcp2515 gCan;

bool Mcp2515::begin() {
  pinMode(D400_CAN_CS_PIN, OUTPUT);
  digitalWrite(D400_CAN_CS_PIN, HIGH);
  pinMode(D400_CAN_INT_PIN, INPUT_PULLUP);

  SPI.begin(D400_SPI_SCK_PIN, D400_SPI_MISO_PIN, D400_SPI_MOSI_PIN, D400_CAN_CS_PIN);
  SPI.setFrequency(D400_MCP_SPI_HZ);

  reset();
  uint8_t mode = readRegister(CANSTAT) & MODE_MASK;
  return mode == MODE_CONFIG;
}

bool Mcp2515::configure(bool listenOnly) {
  reset();
  if (!setMode(MODE_CONFIG)) return false;

  if (D400_MCP_CLOCK_MHZ == 8 && D400_CAN_BITRATE == 500000) {
    writeRegister(CNF1, 0x00);
    writeRegister(CNF2, 0x90);
    writeRegister(CNF3, 0x82);
  } else if (D400_MCP_CLOCK_MHZ == 8 && D400_CAN_BITRATE == 250000) {
    writeRegister(CNF1, 0x00);
    writeRegister(CNF2, 0xB1);
    writeRegister(CNF3, 0x85);
  } else if (D400_MCP_CLOCK_MHZ == 16 && D400_CAN_BITRATE == 500000) {
    writeRegister(CNF1, 0x00);
    writeRegister(CNF2, 0xF0);
    writeRegister(CNF3, 0x86);
  } else if (D400_MCP_CLOCK_MHZ == 16 && D400_CAN_BITRATE == 250000) {
    writeRegister(CNF1, 0x41);
    writeRegister(CNF2, 0xF1);
    writeRegister(CNF3, 0x85);
  } else {
    return false;
  }

  if (D400_MCP_FILTER_IMPORTANT_IDS_ONLY) {
    configureImportantReceiveFilters();
  } else {
    writeRegister(RXB0CTRL, 0x64);
    writeRegister(RXB1CTRL, 0x60);
  }
  writeRegister(CANINTE, 0x03);
  writeRegister(CANINTF, 0x00);
  writeRegister(EFLG, 0x00);

  return setMode(listenOnly ? MODE_LISTEN : MODE_NORMAL);
}

bool Mcp2515::sendFrame(const CanFrame& frame) {
  if (frame.extended || frame.dlc > 8) return false;
  if (readRegister(TXB0CTRL) & TXREQ) abortPendingTx();
  if (readRegister(TXB0CTRL) & TXREQ) return false;

  uint8_t sidH = static_cast<uint8_t>(frame.id >> 3);
  uint8_t sidL = static_cast<uint8_t>((frame.id & 0x07) << 5);

  writeRegister(TXB0SIDH, sidH);
  writeRegister(TXB0SIDL, sidL);
  writeRegister(TXB0EID8, 0x00);
  writeRegister(TXB0EID0, 0x00);
  writeRegister(TXB0DLC, frame.dlc & 0x0F);
  for (uint8_t i = 0; i < frame.dlc; i++) {
    writeRegister(TXB0D0 + i, frame.data[i]);
  }

  command(RTS_TXB0);
  txRequests_++;
  return true;
}

bool Mcp2515::readFrame(CanFrame& frame) {
  uint8_t flags = readRegister(CANINTF);
  if (flags & RX0IF) {
    readRxBuffer(RXB0SIDH, frame);
    bitModify(CANINTF, RX0IF, 0x00);
    return true;
  }
  if (flags & RX1IF) {
    readRxBuffer(RXB1SIDH, frame);
    bitModify(CANINTF, RX1IF, 0x00);
    return true;
  }
  return false;
}

uint8_t Mcp2515::errorFlags() {
  return readRegister(EFLG);
}

uint8_t Mcp2515::rxOverflowFlags() {
  return readRegister(EFLG) & (RX0OVR | RX1OVR);
}

void Mcp2515::clearRxOverflowFlags() {
  bitModify(EFLG, RX0OVR | RX1OVR, 0x00);
}

uint8_t Mcp2515::status() {
  select();
  SPI.transfer(READ_STATUS);
  uint8_t value = SPI.transfer(0x00);
  deselect();
  return value;
}

void Mcp2515::select() {
  digitalWrite(D400_CAN_CS_PIN, LOW);
}

void Mcp2515::deselect() {
  digitalWrite(D400_CAN_CS_PIN, HIGH);
}

void Mcp2515::command(uint8_t instruction) {
  select();
  SPI.transfer(instruction);
  deselect();
}

void Mcp2515::reset() {
  command(RESET);
  delay(10);
}

uint8_t Mcp2515::readRegister(uint8_t address) {
  select();
  SPI.transfer(READ);
  SPI.transfer(address);
  uint8_t value = SPI.transfer(0x00);
  deselect();
  return value;
}

void Mcp2515::writeRegister(uint8_t address, uint8_t value) {
  select();
  SPI.transfer(WRITE);
  SPI.transfer(address);
  SPI.transfer(value);
  deselect();
}

void Mcp2515::bitModify(uint8_t address, uint8_t mask, uint8_t value) {
  select();
  SPI.transfer(BIT_MODIFY);
  SPI.transfer(address);
  SPI.transfer(mask);
  SPI.transfer(value);
  deselect();
}

void Mcp2515::writeStandardIdRegisters(uint8_t base, uint16_t id) {
  id &= 0x07FF;
  writeRegister(base, static_cast<uint8_t>(id >> 3));
  writeRegister(base + 1, static_cast<uint8_t>((id & 0x07) << 5));
  writeRegister(base + 2, 0x00);
  writeRegister(base + 3, 0x00);
}

void Mcp2515::configureImportantReceiveFilters() {
  writeStandardIdRegisters(RXM0SIDH, 0x07FF);
  writeStandardIdRegisters(RXM1SIDH, 0x07FF);
  writeStandardIdRegisters(RXF0SIDH, 0x447);
  writeStandardIdRegisters(RXF1SIDH, 0x30C);
  writeStandardIdRegisters(RXF2SIDH, 0x301);
  writeStandardIdRegisters(RXF3SIDH, 0x302);
  writeStandardIdRegisters(RXF4SIDH, 0x303);
  writeStandardIdRegisters(RXF5SIDH, 0x303);
  writeRegister(RXB0CTRL, 0x00);
  writeRegister(RXB1CTRL, 0x00);
}

bool Mcp2515::setMode(uint8_t mode) {
  bitModify(CANCTRL, MODE_MASK, mode);
  uint32_t start = millis();
  while (millis() - start < 100) {
    if ((readRegister(CANSTAT) & MODE_MASK) == mode) return true;
    delay(2);
  }
  return false;
}

void Mcp2515::abortPendingTx() {
  bitModify(CANCTRL, ABAT, ABAT);
  delay(2);
  bitModify(CANCTRL, ABAT, 0x00);
  bitModify(TXB0CTRL, TXREQ, 0x00);
}

void Mcp2515::readRxBuffer(uint8_t base, CanFrame& frame) {
  uint8_t rxBytes[13] = {0};
  select();
  SPI.transfer(READ);
  SPI.transfer(base);
  for (uint8_t i = 0; i < sizeof(rxBytes); i++) {
    rxBytes[i] = SPI.transfer(0x00);
  }
  deselect();

  uint8_t sidH = rxBytes[0];
  uint8_t sidL = rxBytes[1];
  uint8_t eid8 = rxBytes[2];
  uint8_t eid0 = rxBytes[3];
  uint8_t dlc = rxBytes[4] & 0x0F;

  frame.extended = (sidL & 0x08) != 0;
  if (frame.extended) {
    frame.id = (static_cast<uint32_t>(sidH) << 21) |
               (static_cast<uint32_t>(sidL & 0xE0) << 13) |
               (static_cast<uint32_t>(sidL & 0x03) << 16) |
               (static_cast<uint32_t>(eid8) << 8) |
               eid0;
  } else {
    frame.id = (static_cast<uint32_t>(sidH) << 3) | (sidL >> 5);
  }

  frame.dlc = dlc > 8 ? 8 : dlc;
  for (uint8_t i = 0; i < frame.dlc; i++) {
    frame.data[i] = rxBytes[5 + i];
  }
  rxFrames_++;
}
