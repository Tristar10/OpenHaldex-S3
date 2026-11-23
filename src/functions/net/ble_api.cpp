#include "functions/net/ble_api.h"

#include <Arduino.h>
#include <NimBLEDevice.h>

#include "functions/api/api.h"
#include "functions/config/config.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

namespace {

constexpr char kServiceUuid[] = "4f480001-0000-4c44-8000-4f70656e4844";
constexpr char kRxUuid[] = "4f480002-0000-4c44-8000-4f70656e4844";
constexpr char kTxUuid[] = "4f480003-0000-4c44-8000-4f70656e4844";

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
    while (!g_tx->notify(packet, n + 1, conn)) {
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

void apiTask(void* arg) {
  (void)arg;
  PendingRequest req = {};
  for (;;) {
    if (xQueueReceive(g_request_queue, &req, portMAX_DELAY) != pdTRUE) {
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
  NimBLECharacteristic* rx =
    service->createCharacteristic(kRxUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  g_tx = service->createCharacteristic(kTxUuid, NIMBLE_PROPERTY::NOTIFY);
  if (!rx || !g_tx) {
    LOG_ERROR("bleapi", "Unable to create API characteristics");
    return false;
  }
  rx->setCallbacks(&g_rx_callbacks);

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
