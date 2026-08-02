#include "sse_transport.h"

#include <errno.h>
#include <sys/select.h>
#include <lwip/sockets.h>

#include "bench_metrics.h"
#include "d400_config.h"

static WiFiClient sseClient;
static bool sseClientActive = false;
static uint32_t sseLastSendMs = 0;
static uint32_t sseLastAcceptedMs = 0;
static uint32_t sseSkippedCount = 0;
static uint32_t sseDroppedCount = 0;

static RideTelemetryBinary cachedBinary{};
static bool cachedBinaryValid = false;

static char cachedHexLine[D400_BINARY_HEX_LINE_MAX];

static void closeSseClient() {
  if (!sseClientActive) return;
  sseClient.stop();
  sseClientActive = false;
}

static bool sseSocketWritable() {
  const int sock = sseClient.fd();
  if (sock < 0) return false;

  fd_set writeSet;
  FD_ZERO(&writeSet);
  FD_SET(sock, &writeSet);
  timeval tv;
  tv.tv_sec = 0;
  tv.tv_usec = 0;
  const int ready = ::select(sock + 1, nullptr, &writeSet, nullptr, &tv);
  return ready > 0 && FD_ISSET(sock, &writeSet);
}

static void noteSseSkipOrStall() {
  sseSkippedCount++;
  if (millis() - sseLastAcceptedMs >= D400_SSE_STALL_TIMEOUT_MS) {
    sseDroppedCount++;
    closeSseClient();
  }
}

static bool sseSendBytes(const char* data, size_t len) {
  if (!sseClientActive || len == 0) return false;
  if (len + 8 > D400_SSE_FRAME_BUF_MAX) {
    noteSseSkipOrStall();
    return false;
  }
  if (D400_SSE_BACKPRESSURE_CHECK && !sseSocketWritable()) {
    noteSseSkipOrStall();
    return false;
  }

  char frame[D400_SSE_FRAME_BUF_MAX];
  memcpy(frame, "data: ", 6);
  memcpy(frame + 6, data, len);
  frame[6 + len] = '\n';
  frame[7 + len] = '\n';
  const size_t framed = len + 8;

  const int sock = sseClient.fd();
  if (sock < 0) {
    sseDroppedCount++;
    closeSseClient();
    return false;
  }

  BenchScope scope(gBenchSseSendUs);
  const int sent = ::send(sock, frame, framed, MSG_DONTWAIT);
  if (sent < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      noteSseSkipOrStall();
      return false;
    }
    sseDroppedCount++;
    closeSseClient();
    return false;
  }
  if (static_cast<size_t>(sent) < framed) {
    sseDroppedCount++;
    closeSseClient();
    return false;
  }

  sseLastAcceptedMs = millis();
  return true;
}

void sseInit(WebServer& http) {
  (void)http;
}

void sseHandleEvents(WebServer& http) {
  if (sseClientActive) {
    sseDroppedCount++;
    closeSseClient();
  }

  sseClient = http.client();
  sseClient.setNoDelay(true);
  sseClient.println("HTTP/1.1 200 OK");
  sseClient.println("Content-Type: text/event-stream");
  sseClient.println("Cache-Control: no-cache");
  sseClient.println("Connection: keep-alive");
  sseClient.println("Access-Control-Allow-Origin: *");
  sseClient.println();

  sseClientActive = true;
  sseLastSendMs = 0;
  sseLastAcceptedMs = millis();
}

void ssePublishBinary(const RideTelemetryBinary& payload) {
  cachedBinary = payload;
  cachedBinaryValid = true;

  size_t hexLen = formatRideTelemetryHex(cachedHexLine, sizeof(cachedHexLine), payload);
  if (hexLen == 0) return;

  if (!sseClientActive) return;
  if (millis() - sseLastSendMs < D400_TELEMETRY_INTERVAL_MS) return;
  sseLastSendMs = millis();
  sseSendBytes(cachedHexLine, hexLen);
}

void sseMaintain() {
  if (!sseClientActive) return;
  if (!sseClient.connected()) closeSseClient();
}

uint32_t sseSkippedFrames() {
  return sseSkippedCount;
}

uint32_t sseDroppedClients() {
  return sseDroppedCount;
}

const RideTelemetryBinary* sseCachedBinary() {
  return cachedBinaryValid ? &cachedBinary : nullptr;
}
