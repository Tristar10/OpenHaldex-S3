#include "functions/telemetry/mmi_link.h"

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>

#include "functions/config/config.h"
#include "functions/core/state.h"

#include "freertos/FreeRTOS.h"

namespace {

// Must match ttlink on the head unit (altscreen repo, gauges/headunit/ttlink.c).
// The stock MMI firewall passes UDP 49153-49162 from hotspot clients.
constexpr uint16_t kPort = 49160;
constexpr uint32_t kKey = 0;                 // ttlink -k
constexpr uint32_t kStreamIntervalMs = 50;   // 20 Hz once the head unit answers
constexpr uint32_t kProbeIntervalMs = 1000;  // until then, 1 Hz
constexpr uint32_t kLinkTimeoutMs = 3000;    // no ack this long -> back to probing
constexpr uint32_t kIdleIntervalMs = 500;    // STA not connected

// Channel ids. Keep in sync with ttlink.c and gauge-send.py.
enum : uint16_t {
  CH_RPM = 1,
  CH_SPEED = 2,          // km/h
  CH_PEDAL = 3,          // %
  CH_TORQUE = 4,         // Nm (DSG gearbox input torque)
  CH_COOLANT = 5,        // degC
  CH_OIL = 6,            // degC
  CH_IAT = 7,            // degC
  CH_BOOST = 8,          // kPa above atmospheric
  CH_HALDEX_REQ = 10,    // % (OpenHaldex lock target)
  CH_HALDEX_ACT = 11,    // % (reported engagement)
  CH_MODE = 12,          // openhaldex mode number
  CH_GEAR = 13,          // raw gear nibble
  CH_TRANS = 16,         // degC, DSG sump
  CH_OIL_PRESS = 18,     // bar
  CH_CLUTCH_TEMP = 19,   // degC, Haldex clutch (UDS, ~2 s)
  CH_STEERING = 20,      // deg
  CH_BRAKE = 21,         // bar
  CH_UPTIME = 60,        // s
  CH_RSSI = 61,          // dBm
  CH_SENT = 62,
};

WiFiUDP g_udp;
bool g_udp_open = false;
bool g_started = false;

portMUX_TYPE g_stats_mux = portMUX_INITIALIZER_UNLOCKED;
MmiLinkStats g_stats = {};
uint32_t g_last_ack_ms = 0;

// Send times by sequence number, for round-trip time.
constexpr size_t kRing = 64;
uint32_t g_sent_ms[kRing];
uint16_t g_sent_seq[kRing];

void put16(uint8_t* p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

void put32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

uint32_t get32(const uint8_t* p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

size_t addValue(uint8_t* buf, size_t len, uint8_t& count, uint16_t id, float value) {
  put16(buf + len, id);
  put32(buf + len + 2, (uint32_t)(int32_t)lroundf(value * 1000.0f));
  count++;
  return len + 6;
}

size_t buildDatagram(uint8_t* buf, uint16_t seq, uint32_t sent) {
  memcpy(buf, "TTG1", 4);
  put32(buf + 4, kKey);
  put16(buf + 8, seq);
  buf[10] = 0;  // flags
  uint8_t count = 0;
  size_t len = 12;

  len = addValue(buf, len, count, CH_RPM, received_vehicle_rpm);
  len = addValue(buf, len, count, CH_SPEED, received_vehicle_speed);
  len = addValue(buf, len, count, CH_PEDAL, constrain(received_pedal_value, 0.0f, 100.0f));
  len = addValue(buf, len, count, CH_TORQUE, received_engine_torque_nm);
  len = addValue(buf, len, count, CH_COOLANT, received_coolant_temp_c);
  len = addValue(buf, len, count, CH_OIL, received_oil_temp_c);
  len = addValue(buf, len, count, CH_IAT, received_intake_air_temp_c);
  len = addValue(buf, len, count, CH_BOOST, received_vehicle_boost / 10.0f);
  len = addValue(buf, len, count, CH_HALDEX_REQ, lock_target);
  len = addValue(buf, len, count, CH_HALDEX_ACT, received_haldex_engagement);
  len = addValue(buf, len, count, CH_MODE, (float)(int)openhaldexEffectiveMode());
  len = addValue(buf, len, count, CH_GEAR, received_gear_number);
  len = addValue(buf, len, count, CH_TRANS, received_trans_temp_c);
  len = addValue(buf, len, count, CH_OIL_PRESS, received_oil_pressure_decibar / 10.0f);
  if (received_haldex_clutch_temp_valid) {
    len = addValue(buf, len, count, CH_CLUTCH_TEMP, received_haldex_clutch_temp_c);
  }
  len = addValue(buf, len, count, CH_STEERING, received_steering_angle_decidegrees / 10.0f);
  len = addValue(buf, len, count, CH_BRAKE, received_brake_pressure_decibar / 10.0f);
  len = addValue(buf, len, count, CH_UPTIME, millis() / 1000.0f);
  len = addValue(buf, len, count, CH_RSSI, (float)WiFi.RSSI());
  len = addValue(buf, len, count, CH_SENT, (float)sent);

  buf[11] = count;
  return len;
}

// Drains any "TTA1" acks: echoed seq u16 @4, reserved u16 @6, rx u32 @8,
// lost u32 @12, head-unit uptime u32 @16.
void readAcks(IPAddress gateway) {
  uint8_t in[32];
  for (;;) {
    const int size = g_udp.parsePacket();
    if (size <= 0) {
      return;
    }
    const int n = g_udp.read(in, sizeof(in));
    if (n < 20 || memcmp(in, "TTA1", 4) != 0 || g_udp.remoteIP() != gateway) {
      continue;
    }
    const uint16_t seq = (uint16_t)((in[4] << 8) | in[5]);
    const uint32_t now = millis();
    const size_t slot = seq % kRing;

    portENTER_CRITICAL(&g_stats_mux);
    if (g_sent_seq[slot] == seq) {
      const uint32_t rtt = now - g_sent_ms[slot];
      g_stats.rttLastMs = rtt;
      if (rtt > g_stats.rttMaxMs) {
        g_stats.rttMaxMs = rtt;
      }
    }
    g_stats.acks++;
    g_stats.huRx = get32(in + 8);
    g_stats.huLost = get32(in + 12);
    g_last_ack_ms = now;
    portEXIT_CRITICAL(&g_stats_mux);
  }
}

// Called from loop() (~100 Hz). Never blocks: one non-blocking UDP send at
// most per call, plus draining any queued acks. Keeps its state in statics so
// it needs no task of its own (saves a 4 KB stack).
void mmiLinkTickImpl() {
  static uint16_t seq = 0;
  static uint32_t sent = 0;
  static bool was_linked = false;
  static uint32_t last_gateway = 0;
  static uint32_t next_due_ms = 0;

  const uint32_t now = millis();
  if ((int32_t)(now - next_due_ms) < 0) {
    return;
  }

  const bool sta = (WiFi.status() == WL_CONNECTED);
  const IPAddress gateway = sta ? WiFi.gatewayIP() : IPAddress(0, 0, 0, 0);

  if (!sta || gateway == IPAddress(0, 0, 0, 0)) {
    portENTER_CRITICAL(&g_stats_mux);
    g_stats.staConnected = false;
    g_stats.linked = false;
    g_stats.gateway = 0;
    portEXIT_CRITICAL(&g_stats_mux);
    if (was_linked) {
      LOG_WARN("mmi", "link down (STA disconnected)");
      was_linked = false;
    }
    last_gateway = 0;
    next_due_ms = now + kIdleIntervalMs;
    return;
  }

  if (!g_udp_open) {
    g_udp_open = g_udp.begin(0) == 1;  // any local port; acks come back to it
    if (!g_udp_open) {
      LOG_ERROR("mmi", "UDP socket open failed");
      next_due_ms = now + kProbeIntervalMs;
      return;
    }
  }

  if ((uint32_t)gateway != last_gateway) {
    last_gateway = (uint32_t)gateway;
    LOG_INFO("mmi", "STA gateway %s, probing udp %u", gateway.toString().c_str(), (unsigned int)kPort);
    // OpenHaldex's own AP is 192.168.4.1/24; a hotspot on the same subnet
    // cannot be reached reliably.
    if (gateway[0] == 192 && gateway[1] == 168 && gateway[2] == 4) {
      LOG_WARN("mmi", "STA gateway is on the AP subnet 192.168.4.x");
    }
  }

  readAcks(gateway);

  uint8_t buf[12 + 6 * 24];
  const size_t len = buildDatagram(buf, seq, sent);
  if (g_udp.beginPacket(gateway, kPort) == 1) {
    g_udp.write(buf, len);
    if (g_udp.endPacket() == 1) {
      sent++;
    }
  }

  portENTER_CRITICAL(&g_stats_mux);
  g_sent_seq[seq % kRing] = seq;
  g_sent_ms[seq % kRing] = now;
  g_stats.staConnected = true;
  g_stats.gateway = (uint32_t)gateway;
  g_stats.sent = sent;
  const bool linked = g_last_ack_ms != 0 && (now - g_last_ack_ms) < kLinkTimeoutMs;
  g_stats.linked = linked;
  portEXIT_CRITICAL(&g_stats_mux);
  seq++;

  if (linked != was_linked) {
    if (linked) {
      LOG_INFO("mmi", "link up, head unit %s answering", gateway.toString().c_str());
    } else {
      LOG_WARN("mmi", "link lost, back to 1 Hz probes");
    }
    was_linked = linked;
  }

  // Fixed cadence: step from the previous due time, but never queue a burst
  // after a stall.
  const uint32_t interval = linked ? kStreamIntervalMs : kProbeIntervalMs;
  next_due_ms += interval;
  if ((int32_t)(now - next_due_ms) >= 0) {
    next_due_ms = now + interval;
  }
}

} // namespace

void mmiLinkGetStats(MmiLinkStats& out) {
  portENTER_CRITICAL(&g_stats_mux);
  out = g_stats;
  const uint32_t last = g_last_ack_ms;
  portEXIT_CRITICAL(&g_stats_mux);
  out.lastAckAgeMs = last == 0 ? 0 : millis() - last;
}

void mmiLinkInit() {
  if (g_started) {
    return;
  }
  for (size_t i = 0; i < kRing; i++) {
    g_sent_seq[i] = 0xFFFF;
  }
  g_started = true;
  LOG_INFO("mmi", "MMI link ready, udp %u to STA gateway", (unsigned int)kPort);
}

void mmiLinkTick() {
  if (g_started) {
    mmiLinkTickImpl();
  }
}
