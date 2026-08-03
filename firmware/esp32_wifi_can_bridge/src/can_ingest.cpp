#include "can_ingest.h"

#include "d400_config.h"
#include "passive_decode.h"

bool gCanReady = false;
uint32_t gDroppedCorruptFrames = 0;
uint32_t gMcpRxOverflowEvents = 0;
uint32_t gMcpReinitAttempts = 0;
uint32_t gLastMcpRxOverflowMs = 0;

static uint32_t lastMcpReinitMs = 0;

#ifdef D400_LAB_BUILD
static const size_t CAN_RECENT_COUNT = 24;
static const size_t CAN_ID_STATS_COUNT = 48;

struct RecentCanFrame {
  uint32_t ms = 0;
  uint32_t id = 0;
  bool extended = false;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

struct CanIdStat {
  bool used = false;
  uint32_t id = 0;
  bool extended = false;
  uint32_t count = 0;
  uint32_t lastMs = 0;
  uint8_t dlc = 0;
  uint8_t data[8] = {0};
};

static RecentCanFrame recentCanFrames[CAN_RECENT_COUNT];
static CanIdStat canIdStats[CAN_ID_STATS_COUNT];
static size_t recentCanWriteIndex = 0;
static uint32_t recentCanStored = 0;

void rememberCanFrame(const CanFrame& frame) {
  uint32_t now = millis();

  RecentCanFrame& recent = recentCanFrames[recentCanWriteIndex];
  recent.ms = now;
  recent.id = frame.id;
  recent.extended = frame.extended;
  recent.dlc = frame.dlc;
  for (uint8_t i = 0; i < 8; i++) {
    recent.data[i] = i < frame.dlc ? frame.data[i] : 0;
  }

  recentCanWriteIndex = (recentCanWriteIndex + 1) % CAN_RECENT_COUNT;
  if (recentCanStored < CAN_RECENT_COUNT) recentCanStored++;

  size_t statIndex = CAN_ID_STATS_COUNT;
  size_t firstFreeIndex = CAN_ID_STATS_COUNT;
  size_t oldestIndex = 0;
  uint32_t oldestMs = UINT32_MAX;

  for (size_t i = 0; i < CAN_ID_STATS_COUNT; i++) {
    CanIdStat& stat = canIdStats[i];
    if (stat.used && stat.id == frame.id && stat.extended == frame.extended) {
      statIndex = i;
      break;
    }
    if (!stat.used && firstFreeIndex == CAN_ID_STATS_COUNT) firstFreeIndex = i;
    if (stat.used && stat.lastMs < oldestMs) {
      oldestMs = stat.lastMs;
      oldestIndex = i;
    }
  }

  if (statIndex == CAN_ID_STATS_COUNT) {
    statIndex = firstFreeIndex != CAN_ID_STATS_COUNT ? firstFreeIndex : oldestIndex;
    canIdStats[statIndex].count = 0;
  }

  CanIdStat& stat = canIdStats[statIndex];
  stat.used = true;
  stat.id = frame.id;
  stat.extended = frame.extended;
  stat.count++;
  stat.lastMs = now;
  stat.dlc = frame.dlc;
  for (uint8_t i = 0; i < 8; i++) {
    stat.data[i] = i < frame.dlc ? frame.data[i] : 0;
  }
}
#endif

bool isImportantFilteredStandardId(uint32_t id) {
  return id == 0x301 || id == 0x302 || id == 0x303 || id == 0x30C || id == 0x447;
}

bool shouldDropCanFrame(const CanFrame& frame) {
  if (frame.dlc > 8) return true;

  if (D400_MCP_FILTER_IMPORTANT_IDS_ONLY) {
    if (D400_DROP_EXTENDED_FRAMES && frame.extended) return true;
    if (!frame.extended && !isImportantFilteredStandardId(frame.id)) return true;
  }

  bool allBytesFf = frame.dlc > 0;
  for (uint8_t i = 0; i < frame.dlc; i++) {
    if (frame.data[i] != 0xFF) {
      allBytesFf = false;
      break;
    }
  }
  if (frame.extended && frame.id == 0x1FFFFFFF && allBytesFf) return true;
  if (!frame.extended && frame.id == 0x30C && frame.dlc == 2 &&
      frame.data[0] == 0xFF && frame.data[1] == 0xFF) {
    return true;
  }

  return false;
}

bool ingestCanFrame(const CanFrame& frame) {
  if (shouldDropCanFrame(frame)) {
    gDroppedCorruptFrames++;
    return false;
  }

#ifdef D400_LAB_BUILD
  rememberCanFrame(frame);
#endif
  return applyPassiveCanFrame(frame);
}

void serviceMcpRxOverflows() {
  if (!gCanReady) return;
  uint8_t overflowFlags = gCan.rxOverflowFlags();
  if (overflowFlags == 0) return;
  if (overflowFlags & 0x40) gMcpRxOverflowEvents++;
  if (overflowFlags & 0x80) gMcpRxOverflowEvents++;
  gLastMcpRxOverflowMs = millis();
  gCan.clearRxOverflowFlags();
}

void maintainCanHealth() {
  if (!D400_CAN_LISTEN_ONLY) return;

  uint32_t now = millis();
  if (now - lastMcpReinitMs < D400_CAN_REINIT_COOLDOWN_MS) return;

  if (!gCanReady) {
    lastMcpReinitMs = now;
    gMcpReinitAttempts++;
    gCanReady = gCan.begin() && gCan.configure(D400_CAN_LISTEN_ONLY);
    return;
  }

  uint32_t lastCanFrameMs = passiveLastCanFrameMs();
  bool stale = false;
  if (lastCanFrameMs == 0) {
    stale = now >= D400_CAN_STALE_REINIT_MS;
  } else {
    stale = now - lastCanFrameMs >= D400_CAN_STALE_REINIT_MS;
  }
  if (!stale) return;

  lastMcpReinitMs = now;
  gMcpReinitAttempts++;
  gCanReady = gCan.configure(D400_CAN_LISTEN_ONLY);
  if (gCanReady) gLastMcpRxOverflowMs = 0;
}

void setupCanBridge() {
  gCanReady = gCan.begin() && gCan.configure(D400_CAN_LISTEN_ONLY);
}

void processCanFrames() {
  if (!D400_CAN_LISTEN_ONLY) return;
  if (!gCanReady) {
    maintainCanHealth();
    return;
  }

  CanFrame frame;
  uint8_t drained = 0;
  while (drained < D400_CAN_DRAIN_LIMIT && gCan.readFrame(frame)) {
    ingestCanFrame(frame);
    drained++;
  }

  serviceMcpRxOverflows();
  maintainCanHealth();
}
