#include "twai_can.h"

#include "driver/twai.h"

#include "d400_config.h"

TwaiCan gCan;

static bool fillTwaiTiming(twai_timing_config_t* timing) {
  if (D400_CAN_BITRATE == 500000) {
    *timing = TWAI_TIMING_CONFIG_500KBITS();
    return true;
  }
  if (D400_CAN_BITRATE == 250000) {
    *timing = TWAI_TIMING_CONFIG_250KBITS();
    return true;
  }
  return false;
}

void TwaiCan::stopAndUninstall() {
  if (!installed_) return;
  twai_stop();
  twai_driver_uninstall();
  installed_ = false;
}

bool TwaiCan::begin() {
  stopAndUninstall();
  overflowLatched_ = 0;
  return true;
}

bool TwaiCan::configure(bool listenOnly) {
  twai_timing_config_t timing;
  if (!fillTwaiTiming(&timing)) return false;

  stopAndUninstall();

  twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT(
      static_cast<gpio_num_t>(D400_TWAI_TX_PIN),
      static_cast<gpio_num_t>(D400_TWAI_RX_PIN),
      listenOnly ? TWAI_MODE_LISTEN_ONLY : TWAI_MODE_NORMAL);
  general.rx_queue_len = D400_TWAI_RX_QUEUE_LEN;
  general.alerts_enabled = TWAI_ALERT_RX_QUEUE_FULL | TWAI_ALERT_BUS_OFF |
                           TWAI_ALERT_ERR_PASS | TWAI_ALERT_RX_FIFO_OVERRUN;

  twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  if (twai_driver_install(&general, &timing, &filter) != ESP_OK) return false;
  installed_ = true;

  if (twai_start() != ESP_OK) {
    stopAndUninstall();
    return false;
  }
  return true;
}

bool TwaiCan::sendFrame(const CanFrame& frame) {
  if (frame.dlc > 8) return false;

  twai_message_t msg = {};
  msg.identifier = frame.id;
  msg.extd = frame.extended;
  msg.data_length_code = frame.dlc;
  for (uint8_t i = 0; i < frame.dlc; i++) {
    msg.data[i] = frame.data[i];
  }

  if (twai_transmit(&msg, 0) != ESP_OK) return false;
  txRequests_++;
  return true;
}

bool TwaiCan::readFrame(CanFrame& frame) {
  twai_message_t msg;
  if (twai_receive(&msg, 0) != ESP_OK) return false;

  frame.id = msg.identifier;
  frame.extended = msg.extd;
  frame.dlc = msg.data_length_code > 8 ? 8 : msg.data_length_code;
  for (uint8_t i = 0; i < frame.dlc; i++) {
    frame.data[i] = msg.data[i];
  }
  rxFrames_++;
  return true;
}

uint8_t TwaiCan::errorFlags() {
  twai_status_info_t info;
  if (twai_get_status_info(&info) != ESP_OK) return 0;
  uint8_t flags = 0;
  if (info.state == TWAI_STATE_BUS_OFF) flags |= 0x01;
  if (info.state == TWAI_STATE_RECOVERING) flags |= 0x02;
  if (info.tx_error_counter > 0) flags |= 0x04;
  if (info.rx_error_counter > 0) flags |= 0x08;
  return flags;
}

uint8_t TwaiCan::rxOverflowFlags() {
  uint32_t alerts = 0;
  if (twai_read_alerts(&alerts, 0) == ESP_OK) {
    if (alerts & (TWAI_ALERT_RX_QUEUE_FULL | TWAI_ALERT_RX_FIFO_OVERRUN)) {
      overflowLatched_ = 1;
    }
  }
  return overflowLatched_;
}

void TwaiCan::clearRxOverflowFlags() {
  overflowLatched_ = 0;
}

uint8_t TwaiCan::status() {
  twai_status_info_t info;
  if (twai_get_status_info(&info) != ESP_OK) return 0;
  return static_cast<uint8_t>(info.state);
}
