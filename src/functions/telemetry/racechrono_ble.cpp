#include "functions/telemetry/racechrono_ble.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_attr.h>

#include "functions/config/config.h"
#include "functions/core/state.h"
#include "functions/net/ble_api.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

namespace {

constexpr char kDeviceName[] = "OpenHaldex-RC";
constexpr uint16_t kRaceChronoServiceUuid = 0x1FF8;
constexpr uint16_t kCanDataCharacteristicUuid = 0x0001;
constexpr uint16_t kCanFilterCharacteristicUuid = 0x0002;
constexpr uint32_t kOpenHaldexTelemetryPid = 0xFFFF0001UL;
// Second decoded packet: chassis values that need firmware-side decoding (e.g.
// the steering sign fix), so RaceChrono doesn't have to decode raw frames.
constexpr uint32_t kOpenHaldexChassisPid = 0xFFFF0002UL;
constexpr uint32_t kOpenHaldexWheelPid = 0xFFFF0003UL;  // FL, FR, RL, RR in 0.01 km/h
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
// True while RaceChrono (or any client) is subscribed to CAN data. Tracked by
// subscription rather than connection, because the iOS app can be connected at
// the same time over the API service without wanting telemetry.
volatile bool g_client_connected = false;
constexpr uint8_t kMaxSubscribers = 4;
uint16_t g_subscribers[kMaxSubscribers] = {BLE_HS_CONN_HANDLE_NONE, BLE_HS_CONN_HANDLE_NONE,
                                           BLE_HS_CONN_HANDLE_NONE, BLE_HS_CONN_HANDLE_NONE};
portMUX_TYPE g_subscriber_lock = portMUX_INITIALIZER_UNLOCKED;

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

  // 0xFFFF0002 (big-endian, for RaceChrono equations):
  //  0-1 steering angle, 0.1 deg, signed    2-3 brake pressure, 0.1 bar, signed
  //  4-5 Haldex clutch temp C, signed (0x7FFF = not yet read)
  //  6 gear   7 flags: bit0 ABS, bit1 ESP, bit2 EDS, bit3 reverse
  uint8_t chassis[8] = {};
  const int16_t steering = received_steering_angle_decidegrees;
  const int16_t brake = received_brake_pressure_decibar;
  const int16_t clutch = received_haldex_clutch_temp_valid ? received_haldex_clutch_temp_c : (int16_t)0x7FFF;
  chassis[0] = (uint8_t)((uint16_t)steering >> 8);
  chassis[1] = (uint8_t)steering;
  chassis[2] = (uint8_t)((uint16_t)brake >> 8);
  chassis[3] = (uint8_t)brake;
  chassis[4] = (uint8_t)((uint16_t)clutch >> 8);
  chassis[5] = (uint8_t)clutch;
  chassis[6] = received_gear_number;
  chassis[7] = (received_abs_active ? 0x01 : 0) | (received_esp_active ? 0x02 : 0) | (received_eds_active ? 0x04 : 0) |
               (received_reverse_active ? 0x08 : 0);
  queuePacket(kOpenHaldexChassisPid, chassis, sizeof(chassis));

  // 0xFFFF0003: four wheel speeds, uint16 big-endian, 0.01 km/h each.
  uint8_t wheels[8];
  for (int i = 0; i < 4; i++) {
    wheels[i * 2] = (uint8_t)(received_wheel_speed_centi[i] >> 8);
    wheels[i * 2 + 1] = (uint8_t)received_wheel_speed_centi[i];
  }
  queuePacket(kOpenHaldexWheelPid, wheels, sizeof(wheels));
}

// Returns the subscriber count after the change.
uint8_t setSubscriber(uint16_t conn, bool subscribed) {
  uint8_t count = 0;
  portENTER_CRITICAL(&g_subscriber_lock);
  int slot = -1;
  for (uint8_t i = 0; i < kMaxSubscribers; i++) {
    if (g_subscribers[i] == conn) {
      slot = i;
    }
  }
  if (subscribed && slot < 0) {
    for (uint8_t i = 0; i < kMaxSubscribers; i++) {
      if (g_subscribers[i] == BLE_HS_CONN_HANDLE_NONE) {
        g_subscribers[i] = conn;
        break;
      }
    }
  } else if (!subscribed && slot >= 0) {
    g_subscribers[slot] = BLE_HS_CONN_HANDLE_NONE;
  }
  for (uint8_t i = 0; i < kMaxSubscribers; i++) {
    if (g_subscribers[i] != BLE_HS_CONN_HANDLE_NONE) {
      count++;
    }
  }
  portEXIT_CRITICAL(&g_subscriber_lock);
  return count;
}

void subscriberChanged(uint16_t conn, bool subscribed) {
  const bool was_connected = g_client_connected;
  const uint8_t count = setSubscriber(conn, subscribed);
  g_client_connected = count > 0;
  if (subscribed && !was_connected) {
    resetFilters();
    LOG_INFO("racechrono", "BLE telemetry client subscribed");
  } else if (!g_client_connected && was_connected) {
    resetFilters();
    LOG_INFO("racechrono", "BLE telemetry client gone");
  }
}

class ServerCallbacks final : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& conn_info) override {
    LOG_INFO("racechrono", "BLE central connected handle=%u peers=%u", (unsigned)conn_info.getConnHandle(),
             (unsigned)server->getConnectedCount());
    // 251-byte link-layer packets and a 15 ms interval (the fastest iOS
    // accepts; Android RaceChrono also honours it). Both are requests - the
    // phone may pick something slower.
    server->setDataLen(conn_info.getConnHandle(), 251);
    server->updateConnParams(conn_info.getConnHandle(), 12, 12, 0, 400);
    // Keep advertising so a second central (RaceChrono + the app) can join.
    NimBLEDevice::startAdvertising();
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& conn_info, int reason) override {
    (void)server;
    subscriberChanged(conn_info.getConnHandle(), false);
    bleApiOnDisconnect(conn_info.getConnHandle());
    LOG_INFO("racechrono", "BLE central disconnected reason=%d", reason);
    NimBLEDevice::startAdvertising();
  }
};

class CanDataCallbacks final : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& conn_info, uint16_t sub_value) override {
    (void)characteristic;
    subscriberChanged(conn_info.getConnHandle(), sub_value != 0);
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
CanDataCallbacks g_can_data_callbacks;
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
  // Throughput: large MTU, 2M PHY preferred (falls back to 1M on older
  // phones). Data length extension is requested per connection in onConnect.
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setDefaultPhy(BLE_GAP_LE_PHY_2M_MASK | BLE_GAP_LE_PHY_1M_MASK,
                              BLE_GAP_LE_PHY_2M_MASK | BLE_GAP_LE_PHY_1M_MASK);
  // Bond with "Just Works" (no PIN). Only the app's API characteristics require
  // encryption; RaceChrono's DIY service stays open as its protocol expects.
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

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
  g_can_data_characteristic->setCallbacks(&g_can_data_callbacks);

  // The app's JSON API shares this server. Not fatal if it fails: RaceChrono
  // telemetry still works.
  bleApiAttach(server);

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
  if (xTaskCreatePinnedToCore(telemetryTask, "racechronoBle", 3072, nullptr, 2, nullptr, OH_APP_TASK_CORE) != pdPASS) {
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
