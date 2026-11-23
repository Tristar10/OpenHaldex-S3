#include "functions/net/ble_api.h"

#include <Arduino.h>
#include <NimBLEDevice.h>

#include "functions/api/api.h"
#include "functions/config/config.h"
#include "functions/core/state.h"
#include "functions/presets/presets.h"
#include "nimble/porting/nimble/include/os/os_mbuf.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

namespace {

constexpr char kServiceUuid[] = "4f480001-0000-4c44-8000-4f70656e4844";
constexpr char kRxUuid[] = "4f480002-0000-4c44-8000-4f70656e4844";
constexpr char kTxUuid[] = "4f480003-0000-4c44-8000-4f70656e4844";
constexpr char kLiveUuid[] = "4f480004-0000-4c44-8000-4f70656e4844";
constexpr uint32_t kLiveIntervalMs = 200;  // 5 Hz compact status for the app.
// Keep this many host buffers free for RaceChrono telemetry; API responses
// wait instead of eating into them.
constexpr int kMbufReserve = 6;

constexpr uint8_t kFlagFirst = 0x01;
constexpr uint8_t kFlagLast = 0x02;
constexpr size_t kMaxRequestBytes = 16 * 1024;
constexpr uint32_t kTaskStackBytes = 6144;
constexpr int kNotifyRetries = 100;

struct PendingRequest {
  uint16_t conn_handle;
  String* message;
};

QueueHandle_t g_request_queue = nullptr;
NimBLECharacteristic* g_tx = nullptr;
NimBLECharacteristic* g_live = nullptr;
NimBLEServer* g_server = nullptr;

// Reassembly state. Only touched from the NimBLE host task (onWrite and the
// disconnect hook), so no locking is needed.
uint16_t g_rx_conn = BLE_HS_CONN_HANDLE_NONE;
String* g_rx_buffer = nullptr;

void dropRxBuffer() {
  delete g_rx_buffer;
  g_rx_buffer = nullptr;
  g_rx_conn = BLE_HS_CONN_HANDLE_NONE;
}

class RxCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& conn_info) override {
    const NimBLEAttValue& value = characteristic->getValue();
    if (value.size() == 0) {
      return;
    }
    const uint8_t flags = value.data()[0];
    const uint16_t conn = conn_info.getConnHandle();

    if (flags & kFlagFirst) {
      dropRxBuffer();
      g_rx_buffer = new String();
      g_rx_conn = conn;
    }
    if (!g_rx_buffer || g_rx_conn != conn) {
      return;  // Fragment without a start, or interleaved from another central.
    }
    if (g_rx_buffer->length() + value.size() - 1 > kMaxRequestBytes) {
      LOG_WARN("bleapi", "Request too large; dropped");
      dropRxBuffer();
      return;
    }
    g_rx_buffer->concat((const char*)value.data() + 1, value.size() - 1);

    if (flags & kFlagLast) {
      PendingRequest req = {conn, g_rx_buffer};
      g_rx_buffer = nullptr;
      g_rx_conn = BLE_HS_CONN_HANDLE_NONE;
      if (xQueueSend(g_request_queue, &req, 0) != pdTRUE) {
        LOG_WARN("bleapi", "Request queue full; dropped");
        delete req.message;
      }
    }
  }
};

RxCallbacks g_rx_callbacks;

volatile int g_live_subscribers = 0;

class LiveCallbacks final : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& conn_info, uint16_t sub_value) override {
    (void)characteristic;
    (void)conn_info;
    if (sub_value) {
      g_live_subscribers++;
    } else if (g_live_subscribers > 0) {
      g_live_subscribers--;
    }
  }
};

LiveCallbacks g_live_callbacks;

bool connectionAlive(uint16_t conn) {
  return g_server && g_server->getPeerInfoByHandle(conn).getConnHandle() == conn;
}

void sendResponse(uint16_t conn, const String& header, const String& body) {
  if (!g_tx || !g_server) {
    return;
  }
  uint16_t mtu = g_server->getPeerMTU(conn);
  if (mtu < 23) mtu = 23;
  const size_t chunk = (size_t)min<uint16_t>(mtu - 3, 512) - 1;

  const size_t total = header.length() + 1 + body.length();
  uint8_t packet[513];
  size_t offset = 0;
  bool first = true;
  while (offset < total || first) {
    const size_t n = min(chunk, total - offset);
    for (size_t i = 0; i < n; i++) {
      const size_t pos = offset + i;
      char c;
      if (pos < header.length()) {
        c = header[pos];
      } else if (pos == header.length()) {
        c = '\n';
      } else {
        c = body[pos - header.length() - 1];
      }
      packet[1 + i] = (uint8_t)c;
    }
    offset += n;
    packet[0] = (first ? kFlagFirst : 0) | (offset >= total ? kFlagLast : 0);
    first = false;

    // notify() fails when the host is out of buffers; back off and retry so a
    // long response (CAN View, logs) streams at whatever rate the link allows.
    int tries = 0;
    while (os_msys_num_free() < kMbufReserve || !g_tx->notify(packet, n + 1, conn)) {
      if (++tries >= kNotifyRetries || !connectionAlive(conn)) {
        LOG_WARN("bleapi", "Response aborted after %u/%u bytes", (unsigned)offset, (unsigned)total);
        return;
      }
      vTaskDelay(pdMS_TO_TICKS(10));
    }
  }
}

void handleMessage(uint16_t conn, const String& message) {
  const int nl = message.indexOf('\n');
  const String header = nl >= 0 ? message.substring(0, nl) : message;
  const String body = nl >= 0 ? message.substring(nl + 1) : String();

  const int sp1 = header.indexOf(' ');
  const int sp2 = sp1 >= 0 ? header.indexOf(' ', sp1 + 1) : -1;
  if (sp1 < 0 || sp2 < 0) {
    sendResponse(conn, "0 400 application/json", "{\"error\":\"bad request\"}");
    return;
  }
  const String id = header.substring(0, sp1);
  const String method = header.substring(sp1 + 1, sp2);
  const String target = header.substring(sp2 + 1);
  const int q = target.indexOf('?');
  const String path = q >= 0 ? target.substring(0, q) : target;
  const String query = q >= 0 ? target.substring(q + 1) : String();

  ApiResponse response;
  apiDispatch(method, path, query, body, response);
  sendResponse(conn, id + " " + String(response.code) + " " + response.type, response.body);
}

uint16_t ageMs(long tick) {
  if (tick <= 0) return 0xFFFF;
  const unsigned long age = millis() - (unsigned long)tick;
  return age > 0xFFFE ? 0xFFFE : (uint16_t)age;
}

// Compact live status (v1, little-endian), so the app doesn't have to poll the
// multi-kilobyte /api/status JSON just to keep the home screen current.
//  0 version (1)          1 mode           2 effective mode
//  3 lock target %        4 lock actual %  5 flags A
//  6-7 Haldex clutch temp C (int16)        8 Haldex generation
//  9 learn progress %     10-11 chassis frame age ms   12-13 Haldex frame age ms
//  14 flags B            15-16 steering wheel angle, 0.1 deg (int16)
//  17 active preset id (255 = none)
// flags A: 0 CAN ready, 1 bus failure, 2 temp protection, 3 coupling open,
//          4 controller disabled, 5 CAN View capture, 6 clutch temp valid, 7 learning
// flags B: 0 chassis bus seen, 1 Haldex bus seen, 2 reverse
void sendLive() {
  if (!g_live || g_live_subscribers == 0 || os_msys_num_free() < kMbufReserve) {
    return;
  }
  uint8_t p[18] = {};
  p[0] = 1;
  p[1] = (uint8_t)state.mode;
  p[2] = (uint8_t)openhaldexEffectiveMode();
  p[3] = (uint8_t)constrain((int)lroundf(lock_target), 0, 100);
  p[4] = (uint8_t)constrain((int)received_haldex_engagement, 0, 100);
  p[5] = (can_ready ? 0x01 : 0) | (isBusFailure ? 0x02 : 0) | (received_temp_protection ? 0x04 : 0) |
         (received_coupling_open ? 0x08 : 0) | (disableController ? 0x10 : 0) |
         (apiCanviewCaptureActive() ? 0x20 : 0) | (received_haldex_clutch_temp_valid ? 0x40 : 0) |
         (haldexLearnActive ? 0x80 : 0);
  const int16_t temp = received_haldex_clutch_temp_c;
  p[6] = (uint8_t)temp;
  p[7] = (uint8_t)(temp >> 8);
  p[8] = haldexGeneration;
  p[9] = haldexLearnStep;
  const uint16_t chs = ageMs(lastCANChassisTick);
  const uint16_t hdx = ageMs(lastCANHaldexTick);
  p[10] = (uint8_t)chs;
  p[11] = (uint8_t)(chs >> 8);
  p[12] = (uint8_t)hdx;
  p[13] = (uint8_t)(hdx >> 8);
  p[14] = (hasCANChassis ? 0x01 : 0) | (hasCANHaldex ? 0x02 : 0) | (received_reverse_active ? 0x04 : 0);
  const int16_t steering = received_steering_angle_decidegrees;
  p[15] = (uint8_t)steering;
  p[16] = (uint8_t)((uint16_t)steering >> 8);
  p[17] = presetsActiveId();
  g_live->notify(p, sizeof(p));
}

void apiTask(void* arg) {
  (void)arg;
  PendingRequest req = {};
  uint32_t last_live_ms = 0;
  for (;;) {
    const uint32_t now = millis();
    if (now - last_live_ms >= kLiveIntervalMs) {
      last_live_ms = now;
      sendLive();
    }
    if (xQueueReceive(g_request_queue, &req, pdMS_TO_TICKS(kLiveIntervalMs / 2)) != pdTRUE) {
      continue;
    }
    if (connectionAlive(req.conn_handle)) {
      handleMessage(req.conn_handle, *req.message);
    }
    delete req.message;
  }
}

}  // namespace

bool bleApiAttach(NimBLEServer* server) {
  if (!server || g_request_queue) {
    return false;
  }
  g_server = server;
  g_request_queue = xQueueCreate(4, sizeof(PendingRequest));
  if (!g_request_queue) {
    LOG_ERROR("bleapi", "Unable to allocate request queue");
    return false;
  }

  NimBLEService* service = server->createService(kServiceUuid);
  if (!service) {
    LOG_ERROR("bleapi", "Unable to create API service");
    return false;
  }
  // Writes require an encrypted (bonded) link: iOS pairs automatically with
  // "Just Works" on the first write. Reading LIVE also triggers pairing, so the
  // app reads it once right after connecting.
  // OH_BLE_API_ENCRYPT=0 only for bench tests from a computer that cannot
  // complete pairing unattended; production builds always require it.
#ifndef OH_BLE_API_ENCRYPT
#define OH_BLE_API_ENCRYPT 1
#endif
  constexpr uint16_t kWriteEnc = OH_BLE_API_ENCRYPT ? NIMBLE_PROPERTY::WRITE_ENC : 0;
  constexpr uint16_t kReadEnc = OH_BLE_API_ENCRYPT ? NIMBLE_PROPERTY::READ_ENC : 0;
  NimBLECharacteristic* rx = service->createCharacteristic(
    kRxUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | kWriteEnc);
  g_tx = service->createCharacteristic(kTxUuid, NIMBLE_PROPERTY::NOTIFY);
  g_live = service->createCharacteristic(kLiveUuid, NIMBLE_PROPERTY::READ | kReadEnc | NIMBLE_PROPERTY::NOTIFY);
  if (!rx || !g_tx || !g_live) {
    LOG_ERROR("bleapi", "Unable to create API characteristics");
    return false;
  }
  rx->setCallbacks(&g_rx_callbacks);
  g_live->setCallbacks(&g_live_callbacks);

  if (xTaskCreatePinnedToCore(apiTask, "bleApi", kTaskStackBytes, nullptr, 1, nullptr, OH_APP_TASK_CORE) != pdPASS) {
    LOG_ERROR("bleapi", "Unable to start API task");
    return false;
  }
  LOG_INFO("bleapi", "BLE API service ready");
  return true;
}

void bleApiOnDisconnect(unsigned short conn_handle) {
  if (g_rx_conn == conn_handle) {
    dropRxBuffer();
  }
}
