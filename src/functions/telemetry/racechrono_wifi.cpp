#include "functions/telemetry/racechrono_wifi.h"

#include <Arduino.h>
#include <WiFi.h>

#include "functions/config/config.h"
#include "functions/core/state.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

namespace {

// Port RaceChrono connects to as a TCP client; enter the controller's AP
// address (192.168.4.1) and this port in RaceChrono's "RaceChrono DIY" >
// "TCP/IP" device settings. See docs/RACECHRONO_WIFI.md.
constexpr uint16_t kTcpPort = 1338;
constexpr uint32_t kTelemetryIntervalMs = 50; // 20 Hz.
// How often we check for a pending TCP connection while idle. The TCP
// handshake itself completes instantly at the network level - RaceChrono's
// connect() returns success right away - but we only notice and start
// sending the first packet the next time this poll fires, so this interval
// is a random (not fixed) startup delay on every connection, up to its full
// value. Small enough here to be well under the write/connect jitter this
// protocol already has to tolerate, while still cheap (one syscall) since it
// only runs while idle, never during normal streaming.
constexpr uint32_t kAcceptPollIntervalMs = 10;

WiFiServer g_server(kTcpPort);
WiFiClient g_client;
bool g_server_started = false;

// $RC3 is a clear-text NMEA-0183-style extension; checksum is the XOR of all
// characters strictly between '$' and '*'.
uint8_t xorChecksum(const char* body, size_t length) {
  uint8_t checksum = 0;
  for (size_t i = 0; i < length; i++) {
    checksum ^= static_cast<uint8_t>(body[i]);
  }
  return checksum;
}

// Builds one $RC3 sentence carrying the OpenHaldex channels in the generic
// analog slots (a1-a10). RaceChrono's RC2/RC3 DIY protocol only carries
// fixed, pre-decoded channels, unlike the raw CAN-ID passthrough the BLE DIY
// protocol supports - see docs/RACECHRONO_WIFI.md for the channel mapping.
size_t buildSentence(char* out, size_t out_size, uint16_t count) {
  const uint16_t speed_kmh = received_vehicle_speed;
  const uint16_t rpm = received_vehicle_rpm;
  const int pedal_percent = (int)lroundf(constrain(received_pedal_value, 0.0f, 100.0f));
  const int lock_actual = constrain((int)received_haldex_engagement, 0, 100);
  const int mode = (int)openhaldexEffectiveMode();
  const int16_t boost_mbar = (int16_t)received_vehicle_boost;
  const uint16_t wheel_fl = received_wheel_speed_fl;
  const uint16_t wheel_fr = received_wheel_speed_fr;
  const uint16_t wheel_rl = received_wheel_speed_rl;
  const uint16_t wheel_rr = received_wheel_speed_rr;
  const int16_t steering_decideg = received_steering_angle_decidegrees;
  const int16_t brake_decibar = received_brake_pressure_decibar;
  const int16_t oil_temp = received_oil_temp_c;
  const int16_t coolant_temp = received_coolant_temp_c;
  const int16_t trans_temp = received_trans_temp_c;
  const int abs_active = received_abs_active ? 1 : 0;
  const int esp_active = received_esp_active ? 1 : 0;
  const int eds_active = received_eds_active ? 1 : 0;
  const int gear = received_gear_number;
  const int16_t oil_pressure_decibar = received_oil_pressure_decibar;
  const int16_t intake_air_temp = received_intake_air_temp_c;
  const int16_t engine_torque_nm = received_engine_torque_nm;

  char count_text[8];
  char rpm_text[8];
  char boost_text[8];
  char speed_text[8];
  char pedal_text[8];
  char lock_actual_text[8];
  char mode_text[4];
  char wheel_fl_text[8];
  char wheel_fr_text[8];
  char wheel_rl_text[8];
  char wheel_rr_text[8];
  char clutch_temp_text[8];
  char steering_text[8];
  char brake_text[8];
  char oil_temp_text[8];
  char coolant_temp_text[8];
  char trans_temp_text[8];
  char abs_text[4];
  char esp_text[4];
  char eds_text[4];
  char gear_text[4];
  char oil_pressure_text[8];
  char iat_text[8];
  char torque_text[8];
  snprintf(count_text, sizeof(count_text), "%u", (unsigned int)count);
  snprintf(rpm_text, sizeof(rpm_text), "%u", (unsigned int)rpm);
  snprintf(boost_text, sizeof(boost_text), "%d", (int)boost_mbar);
  snprintf(speed_text, sizeof(speed_text), "%u", (unsigned int)speed_kmh);
  snprintf(pedal_text, sizeof(pedal_text), "%d", pedal_percent);
  snprintf(lock_actual_text, sizeof(lock_actual_text), "%d", lock_actual);
  snprintf(mode_text, sizeof(mode_text), "%d", mode);
  snprintf(wheel_fl_text, sizeof(wheel_fl_text), "%u", (unsigned int)wheel_fl);
  snprintf(wheel_fr_text, sizeof(wheel_fr_text), "%u", (unsigned int)wheel_fr);
  snprintf(wheel_rl_text, sizeof(wheel_rl_text), "%u", (unsigned int)wheel_rl);
  snprintf(wheel_rr_text, sizeof(wheel_rr_text), "%u", (unsigned int)wheel_rr);
  // RaceChrono's RC2/RC3 analog/accel/gyro fields have no per-channel
  // equation editor, so pre-divide here and send the real decimal value
  // directly rather than relying on a "raw / 10" equation on the phone.
  snprintf(steering_text, sizeof(steering_text), "%.1f", steering_decideg / 10.0f);
  snprintf(brake_text, sizeof(brake_text), "%.1f", brake_decibar / 10.0f);
  snprintf(oil_temp_text, sizeof(oil_temp_text), "%d", (int)oil_temp);
  snprintf(coolant_temp_text, sizeof(coolant_temp_text), "%d", (int)coolant_temp);
  snprintf(trans_temp_text, sizeof(trans_temp_text), "%d", (int)trans_temp);
  snprintf(abs_text, sizeof(abs_text), "%d", abs_active);
  snprintf(esp_text, sizeof(esp_text), "%d", esp_active);
  snprintf(eds_text, sizeof(eds_text), "%d", eds_active);
  snprintf(gear_text, sizeof(gear_text), "%d", gear);
  snprintf(oil_pressure_text, sizeof(oil_pressure_text), "%.1f", oil_pressure_decibar / 10.0f);
  snprintf(iat_text, sizeof(iat_text), "%d", (int)intake_air_temp);
  snprintf(torque_text, sizeof(torque_text), "%d", (int)engine_torque_nm);
  // Empty until the first successful UDS read, rather than showing a
  // fabricated 0 degC before the controller has actually measured anything.
  if (received_haldex_clutch_temp_valid) {
    snprintf(clutch_temp_text, sizeof(clutch_temp_text), "%d", (int)received_haldex_clutch_temp_c);
  } else {
    clutch_temp_text[0] = '\0';
  }

  char body[192];
  // Fields: time,count,xacc,yacc,zacc,gyrox,gyroy,gyroz,rpm/d1,d2,a1..a15.
  // xacc/yacc/zacc/gyrox/gyroy/gyroz are repurposed as plain numeric fields
  // (no IMU on this board) since all 15 analog slots are already in use -
  // unverified whether RaceChrono lets these be freely relabeled like the
  // analog slots; check the live values once flashed.
  const int body_len = snprintf(body, sizeof(body),
                                 "RC3,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                                 /* time  */ "", /* count */ count_text,
                                 /* xacc ABS active   */ abs_text,
                                 /* yacc ESP active   */ esp_text,
                                 /* zacc EDS/XDS active */ eds_text,
                                 /* gyrox gear number */ gear_text,
                                 /* gyroy oil pressure (Bar)    */ oil_pressure_text,
                                 /* gyroz intake air temp */ iat_text,
                                 /* rpm/d1 */ rpm_text, /* d2 boost (mbar) */ boost_text,
                                 /* a1 speed                */ speed_text,
                                 /* a2 pedal %               */ pedal_text,
                                 /* a3 engine torque (Nm)    */ torque_text,
                                 /* a4 actual lock %         */ lock_actual_text,
                                 /* a5 OpenHaldex mode       */ mode_text,
                                 /* a6 wheel speed FL        */ wheel_fl_text,
                                 /* a7 wheel speed FR        */ wheel_fr_text,
                                 /* a8 wheel speed RL        */ wheel_rl_text,
                                 /* a9 wheel speed RR        */ wheel_rr_text,
                                 /* a10 Haldex clutch temp    */ clutch_temp_text,
                                 /* a11 steering angle (deg) */ steering_text,
                                 /* a12 brake pressure (Bar) */ brake_text,
                                 /* a13 oil temp             */ oil_temp_text,
                                 /* a14 coolant temp         */ coolant_temp_text,
                                 /* a15 trans sump temp      */ trans_temp_text);
  if (body_len <= 0 || (size_t)body_len >= sizeof(body)) {
    return 0;
  }

  const uint8_t checksum = xorChecksum(body, (size_t)body_len);
  const int sentence_len = snprintf(out, out_size, "$%s*%02X\r\n", body, checksum);
  if (sentence_len <= 0 || (size_t)sentence_len >= out_size) {
    return 0;
  }
  return (size_t)sentence_len;
}

void racechronoWifiTask(void* arg) {
  (void)arg;
  uint16_t sequence = 0;
  uint32_t last_accept_attempt_ms = 0;
  // RaceChrono has no GPS-synced timestamp to anchor to when `time` is left
  // empty (the correct choice for a non-GPS device - see docs/RACECHRONO_WIFI.md);
  // instead it infers each sample's real timestamp from the counter field,
  // assuming a dead-steady send interval. vTaskDelay() delays a fixed amount
  // from *now*, so any jitter in buildSentence()/g_client.write() (a blocking
  // TCP send) adds directly onto the interval, making the true average rate
  // run slightly slow and drift further out of RaceChrono's sync over a
  // session. vTaskDelayUntil() schedules against a fixed reference tick
  // instead, which cancels that jitter out.
  TickType_t last_wake_tick = xTaskGetTickCount();

  for (;;) {
    if (!g_client || !g_client.connected()) {
      g_client.stop();

      const uint32_t now_ms = millis();
      if (now_ms - last_accept_attempt_ms >= kAcceptPollIntervalMs) {
        last_accept_attempt_ms = now_ms;
        WiFiClient incoming = g_server.accept();
        if (incoming) {
          g_client = incoming;
          LOG_INFO("racechrono", "WiFi client connected ip=%s", g_client.remoteIP().toString().c_str());
        }
      }

      vTaskDelay(pdMS_TO_TICKS(kAcceptPollIntervalMs));
      // Reset the reference tick so a long idle gap before the next connect
      // doesn't cause vTaskDelayUntil() to fire a burst of catch-up iterations.
      last_wake_tick = xTaskGetTickCount();
      continue;
    }

    char sentence[224];
    const size_t sentence_len = buildSentence(sentence, sizeof(sentence), sequence++);
    if (sentence_len > 0) {
      g_client.write(reinterpret_cast<const uint8_t*>(sentence), sentence_len);
    }

    vTaskDelayUntil(&last_wake_tick, pdMS_TO_TICKS(kTelemetryIntervalMs));
  }
}

} // namespace

void racechronoWifiInit() {
  if (g_server_started) {
    return;
  }

  g_server.begin();
  g_server.setNoDelay(true);
  g_server_started = true;

  if (xTaskCreatePinnedToCore(racechronoWifiTask, "racechronoWifi", 4096, nullptr, 1, nullptr, OH_APP_TASK_CORE) !=
      pdPASS) {
    LOG_ERROR("racechrono", "Unable to start RaceChrono WiFi task");
    return;
  }

  LOG_INFO("racechrono", "RaceChrono WiFi bridge ready port=%u", (unsigned int)kTcpPort);
}
