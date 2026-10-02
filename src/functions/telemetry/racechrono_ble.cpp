#include "functions/telemetry/racechrono_ble.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_attr.h>

#include "functions/config/config.h"
#include "functions/core/state.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

namespace {

constexpr char kDeviceName[] = "OpenHaldex-RC";
constexpr uint16_t kRaceChronoServiceUuid = 0x1FF8;
constexpr uint16_t kCanDataCharacteristicUuid = 0x0001;
constexpr uint16_t kCanFilterCharacteristicUuid = 0x0002;
constexpr uint32_t kOpenHaldexTelemetryPid = 0xFFFF0001UL;
constexpr uint16_t kMinNotifyIntervalMs = 20; // Protect the control loop: max 50 Hz per selected PID.
constexpr uint16_t kDefaultTelemetryIntervalMs = 50;
constexpr uint8_t kFilterCapacity = 32;
constexpr uint8_t kQueueDepth = 48;
constexpr uint32_t kBleBootGuardMagic = 0x5243424BUL; // "RCBK"; bump when the guarded startup sequence changes.
constexpr uint32_t kBleStartupDelayMs = 2500;

enum class BleBootPhase : uint8_t {
  Unknown = 0,
  InitializingStack = 1,
  CreatingServer = 2,
  CreatingService = 3,
  CreatingCharacteristics = 4,
  StartingAdvertising = 5,
  StartingTelemetryTask = 6,
  Running = 7,
  Failed = 8,
};

struct BleBootGuard {
  uint32_t magic;
  BleBootPhase phase;
};

// RTC memory survives a software/panic reset but is cleared by removing power.
// If BLE crashes during initialization, the next boot remains usable with BLE
// disabled rather than entering a permanent reboot loop.
RTC_NOINIT_ATTR BleBootGuard g_ble_boot_guard;

struct TelemetryPacket {
  uint32_t pid;
  uint8_t length;
  uint8_t data[8];
};

struct PidFilter {
  uint32_t pid;
  uint32_t last_queued_ms;
  uint16_t interval_ms;
  bool used;
};

QueueHandle_t g_packet_queue = nullptr;
NimBLECharacteristic* g_can_data_characteristic = nullptr;
portMUX_TYPE g_filter_lock = portMUX_INITIALIZER_UNLOCKED;
PidFilter g_filters[kFilterCapacity] = {};
bool g_allow_all = false;
uint16_t g_allow_all_interval_ms = kDefaultTelemetryIntervalMs;
uint32_t g_allow_all_last_queued_ms = 0;
volatile bool g_client_connected = false;

void setBleBootPhase(BleBootPhase phase, const char* message) {
  g_ble_boot_guard.magic = kBleBootGuardMagic;
  g_ble_boot_guard.phase = phase;
  Serial.printf("[racechrono] %s (stage %u)\n", message, (unsigned int)phase);
  Serial.flush();
}

void markBleStartupFailed() {
  g_can_data_characteristic = nullptr;
  if (g_ble_boot_guard.magic != kBleBootGuardMagic || g_ble_boot_guard.phase == BleBootPhase::Unknown ||
      g_ble_boot_guard.phase == BleBootPhase::Running) {
    g_ble_boot_guard.magic = kBleBootGuardMagic;
    g_ble_boot_guard.phase = BleBootPhase::Failed;
  }
}

uint16_t safeInterval(uint16_t requested_ms) {
  return requested_ms < kMinNotifyIntervalMs ? kMinNotifyIntervalMs : requested_ms;
}

void resetFilters() {
  portENTER_CRITICAL(&g_filter_lock);
  g_allow_all = false;
  g_allow_all_interval_ms = kDefaultTelemetryIntervalMs;
  g_allow_all_last_queued_ms = 0;
  for (PidFilter& filter : g_filters) {
    filter = {};
  }
  portEXIT_CRITICAL(&g_filter_lock);

  if (g_packet_queue) {
    xQueueReset(g_packet_queue);
  }
}

void allowAll(uint16_t interval_ms) {
  portENTER_CRITICAL(&g_filter_lock);
  g_allow_all = true;
  g_allow_all_interval_ms = safeInterval(interval_ms);
  g_allow_all_last_queued_ms = 0;
  portEXIT_CRITICAL(&g_filter_lock);
}

void allowPid(uint32_t pid, uint16_t interval_ms) {
  portENTER_CRITICAL(&g_filter_lock);
  PidFilter* free_filter = nullptr;
  for (PidFilter& filter : g_filters) {
    if (filter.used && filter.pid == pid) {
      filter.interval_ms = safeInterval(interval_ms);
      filter.last_queued_ms = 0;
      portEXIT_CRITICAL(&g_filter_lock);
      return;
    }
    if (!filter.used && !free_filter) {
      free_filter = &filter;
    }
  }
  if (free_filter) {
    free_filter->pid = pid;
    free_filter->interval_ms = safeInterval(interval_ms);
    free_filter->last_queued_ms = 0;
    free_filter->used = true;
  }
  portEXIT_CRITICAL(&g_filter_lock);
}

bool filterAllowsNow(uint32_t pid, uint32_t now_ms) {
  bool allowed = false;
  portENTER_CRITICAL(&g_filter_lock);
  if (g_allow_all) {
    if (g_allow_all_last_queued_ms == 0 || (now_ms - g_allow_all_last_queued_ms) >= g_allow_all_interval_ms) {
      g_allow_all_last_queued_ms = now_ms;
      allowed = true;
    }
  } else {
    for (PidFilter& filter : g_filters) {
      if (!filter.used || filter.pid != pid) {
        continue;
      }
      if (filter.last_queued_ms == 0 || (now_ms - filter.last_queued_ms) >= filter.interval_ms) {
        filter.last_queued_ms = now_ms;
        allowed = true;
      }
      break;
    }
  }
  portEXIT_CRITICAL(&g_filter_lock);
  return allowed;
}

void queuePacket(uint32_t pid, const uint8_t* data, uint8_t length) {
  if (!g_client_connected || !g_packet_queue || !data || length == 0 || length > 8) {
    return;
  }
  if (!filterAllowsNow(pid, millis())) {
    return;
  }

  TelemetryPacket packet = {};
  packet.pid = pid;
  packet.length = length;
  memcpy(packet.data, data, length);
  (void)xQueueSend(g_packet_queue, &packet, 0);
}

void queueDecodedTelemetry() {
  uint8_t payload[8] = {};
  const uint16_t speed_x100 = (uint16_t)min((uint32_t)received_vehicle_speed * 100UL, 65535UL);
  const uint16_t rpm = received_vehicle_rpm;
  const float pedal = constrain(received_pedal_value, 0.0f, 100.0f);

  // RaceChrono equation byte helpers decode big-endian values.
  payload[0] = (uint8_t)(speed_x100 >> 8);
  payload[1] = (uint8_t)speed_x100;
  payload[2] = (uint8_t)(rpm >> 8);
  payload[3] = (uint8_t)rpm;
  payload[4] = (uint8_t)(pedal * 2.55f + 0.5f);
  payload[5] = (uint8_t)constrain((int)lroundf(lock_target), 0, 100);
  payload[6] = (uint8_t)constrain((int)received_haldex_engagement, 0, 100);
  payload[7] = (uint8_t)openhaldexEffectiveMode();
  queuePacket(kOpenHaldexTelemetryPid, payload, sizeof(payload));
}

class ServerCallbacks final : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& conn_info) override {
    (void)server;
    (void)conn_info;
    resetFilters();
    g_client_connected = true;
    LOG_INFO("racechrono", "BLE client connected");
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& conn_info, int reason) override {
    (void)server;
    (void)conn_info;
    g_client_connected = false;
    resetFilters();
    LOG_INFO("racechrono", "BLE client disconnected reason=%d", reason);
    NimBLEDevice::startAdvertising();
  }
};

class FilterCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& conn_info) override {
    (void)conn_info;
    const NimBLEAttValue& value = characteristic->getValue();
    const uint8_t* bytes = value.data();
    const size_t length = value.size();
    if (!bytes || length == 0) {
      return;
    }

    if (bytes[0] == 0 && length == 1) {
      resetFilters();
      return;
    }
    if (bytes[0] == 1 && length == 3) {
      allowAll(((uint16_t)bytes[1] << 8) | bytes[2]);
      return;
    }
    if (bytes[0] == 2 && length == 7) {
      const uint16_t interval_ms = ((uint16_t)bytes[1] << 8) | bytes[2];
      const uint32_t pid = ((uint32_t)bytes[3] << 24) | ((uint32_t)bytes[4] << 16) |
                           ((uint32_t)bytes[5] << 8) | bytes[6];
      allowPid(pid, interval_ms);
    }
  }
};

ServerCallbacks g_server_callbacks;
FilterCallbacks g_filter_callbacks;

void telemetryTask(void* arg) {
  (void)arg;
  TelemetryPacket packet = {};
  uint32_t last_decoded_ms = 0;

  for (;;) {
    const uint32_t now_ms = millis();
    if (g_client_connected && (now_ms - last_decoded_ms) >= kDefaultTelemetryIntervalMs) {
      last_decoded_ms = now_ms;
      queueDecodedTelemetry();
    }

    if (xQueueReceive(g_packet_queue, &packet, pdMS_TO_TICKS(10)) == pdTRUE && g_client_connected &&
        g_can_data_characteristic) {
      uint8_t value[12] = {};
      // Packet ID is the one little-endian field in the RaceChrono BLE protocol.
      value[0] = (uint8_t)packet.pid;
      value[1] = (uint8_t)(packet.pid >> 8);
      value[2] = (uint8_t)(packet.pid >> 16);
      value[3] = (uint8_t)(packet.pid >> 24);
      memcpy(&value[4], packet.data, packet.length);
      g_can_data_characteristic->setValue(value, packet.length + 4);
      g_can_data_characteristic->notify();
    }
  }
}

bool initializeBleServer() {
  setBleBootPhase(BleBootPhase::InitializingStack, "Initializing NimBLE stack");
  if (!NimBLEDevice::init(kDeviceName)) {
    LOG_ERROR("racechrono", "NimBLE initialization failed");
    return false;
  }

  setBleBootPhase(BleBootPhase::CreatingServer, "Creating BLE server");
  NimBLEServer* server = NimBLEDevice::createServer();
  if (!server) {
    LOG_ERROR("racechrono", "Unable to create BLE server");
    return false;
  }
  server->setCallbacks(&g_server_callbacks, false);

  setBleBootPhase(BleBootPhase::CreatingService, "Creating RaceChrono service");
  NimBLEService* service = server->createService(NimBLEUUID(kRaceChronoServiceUuid));
  if (!service) {
    LOG_ERROR("racechrono", "Unable to create RaceChrono BLE service");
    return false;
  }

  setBleBootPhase(BleBootPhase::CreatingCharacteristics, "Creating RaceChrono characteristics");
  g_can_data_characteristic = service->createCharacteristic(
    NimBLEUUID(kCanDataCharacteristicUuid), NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* filter_characteristic =
    service->createCharacteristic(NimBLEUUID(kCanFilterCharacteristicUuid), NIMBLE_PROPERTY::WRITE);
  if (!g_can_data_characteristic || !filter_characteristic) {
    LOG_ERROR("racechrono", "Unable to create RaceChrono BLE characteristics");
    return false;
  }
  // Characteristic callbacks are never owned/deleted by NimBLE 2.x.
  filter_characteristic->setCallbacks(&g_filter_callbacks);

  setBleBootPhase(BleBootPhase::StartingAdvertising, "Starting BLE advertising");
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  if (!advertising) {
    LOG_ERROR("racechrono", "Unable to create BLE advertiser");
    return false;
  }
  advertising->addServiceUUID(NimBLEUUID(kRaceChronoServiceUuid));
  advertising->enableScanResponse(true);
  advertising->setName(kDeviceName);
  if (!advertising->start()) {
    LOG_ERROR("racechrono", "Unable to start BLE advertising");
    return false;
  }

  setBleBootPhase(BleBootPhase::StartingTelemetryTask, "Starting telemetry task");
  if (xTaskCreatePinnedToCore(telemetryTask, "racechronoBle", 6144, nullptr, 1, nullptr, OH_APP_TASK_CORE) != pdPASS) {
    LOG_ERROR("racechrono", "Unable to start BLE telemetry task");
    return false;
  }
  return true;
}

} // namespace

void racechronoBleInit() {
  if (g_packet_queue) {
    return;
  }

  if (g_ble_boot_guard.magic == kBleBootGuardMagic && g_ble_boot_guard.phase != BleBootPhase::Unknown &&
      g_ble_boot_guard.phase != BleBootPhase::Running) {
    delay(kBleStartupDelayMs);
    Serial.printf("[racechrono] BLE disabled after startup failed at stage %u; power-cycle to retry\n",
                  (unsigned int)g_ble_boot_guard.phase);
    Serial.flush();
    LOG_ERROR("racechrono", "BLE disabled after an earlier startup failure; power-cycle to retry");
    return;
  }

  g_packet_queue = xQueueCreate(kQueueDepth, sizeof(TelemetryPacket));
  if (!g_packet_queue) {
    LOG_ERROR("racechrono", "Unable to allocate BLE telemetry queue");
    return;
  }

  if (!initializeBleServer()) {
    markBleStartupFailed();
    Serial.println("[racechrono] BLE startup failed; disabled until power cycle");
    Serial.flush();
    return;
  }

  g_ble_boot_guard.phase = BleBootPhase::Running;
  Serial.println("[racechrono] BLE ready as OpenHaldex-RC");
  Serial.flush();
  LOG_INFO("racechrono", "BLE DIY service ready name=%s", kDeviceName);
}

void racechronoBleSubmitChassisFrame(const twai_message_t& frame) {
  if (frame.rtr || frame.data_length_code == 0) {
    return;
  }
  queuePacket(frame.identifier & 0x1FFFFFFFUL, frame.data, min((uint8_t)8, frame.data_length_code));
}
