#include <Arduino.h>
#include <WiFi.h>

#include "functions/api/api.h"  // defines OH_ENABLE_WEB (default 1)

#if OH_ENABLE_WEB
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <DNSServer.h>
#include <ESPAsyncWebServer.h>
#endif

#include "functions/can/can.h"
#include "functions/config/config.h"
#include "functions/core/state.h"
#include "functions/tasks/tasks.h"
#include "functions/storage/storage.h"
#include "functions/storage/filelog.h"
#if OH_ENABLE_WEB
#include "functions/web/web.h"
#include "functions/net/update.h"
#endif
#include "functions/power/power.h"
#include "functions/diag/uds.h"
#include "functions/telemetry/racechrono_ble.h"
#if OH_ENABLE_RC3
#include "functions/telemetry/racechrono_wifi.h"
#endif

#include <esp_heap_caps.h>

#if OH_ENABLE_WEB
static AsyncWebServer server(80);
#endif

// Internal RAM, not PSRAM, is the limit once BLE + CAN + Wi-Fi run together.
// loopTask peaks ~4 KB; Arduino's default reserves 8 KB.
SET_LOOP_TASK_STACK_SIZE(6 * 1024);

#if OH_ENABLE_WEB
static const char* AP_SSID = "OpenHaldex-S3";
static const char* MDNS_NAME = "openhaldex";
static const uint32_t WIFI_STA_RETRY_MS = 10000;
static const char* OTA_VERSION_URL = "https://openhaldex.dev/release/s3/version.json";
static volatile bool g_internet_ok = false;
static DNSServer g_ap_dns;
static bool g_ap_dns_running = false;
static bool g_ap_started = false;
static String g_ap_password_applied;
static uint32_t g_sta_last_attempt_ms = 0;
static String g_sta_last_attempt_ssid;

static String apPasswordForSoftAp() {
  String ap_pass;
  (void)storageGetWifiApPassword(ap_pass);
  if (ap_pass.length() == 0) {
    return String("");
  }
  if (ap_pass.length() < 8 || ap_pass.length() > 63) {
    LOG_WARN("wifi", "Ignoring invalid AP password length=%d (must be 8..63)", ap_pass.length());
    return String("");
  }
  return ap_pass;
}

bool wifiInternetOk() {
  return g_internet_ok;
}

// Lightweight connectivity probe for OTA status.
// Only runs DNS lookup when STA is connected.
static void internetCheckTask(void* arg) {
  (void)arg;
  bool last_internet_ok = false;
  bool internet_state_known = false;
  for (;;) {
    if (WiFi.status() == WL_CONNECTED) {
      WiFiClientSecure client;
      client.setTimeout(8000);
      client.setHandshakeTimeout(8000);
      client.setInsecure();
      HTTPClient http;
      http.setTimeout(8000);
      http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
      http.setRedirectLimit(3);

      if (http.begin(client, OTA_VERSION_URL)) {
        int code = http.GET();
        g_internet_ok = (code == 200);
        http.end();
      } else {
        g_internet_ok = false;
      }
    } else {
      g_internet_ok = false;
    }

    if (!internet_state_known || g_internet_ok != last_internet_ok) {
      if (g_internet_ok) {
        LOG_INFO("wifi", "Internet connectivity check: online");
      } else {
        LOG_WARN("wifi", "Internet connectivity check: offline");
      }
      last_internet_ok = g_internet_ok;
      internet_state_known = true;
    }

    vTaskDelay(pdMS_TO_TICKS(30000));
  }
}

// Advertise openhaldex.local on active interfaces.
static void startMdns() {
  MDNS.end();
  delay(50);
  for (uint8_t i = 0; i < 3; i++) {
    if (MDNS.begin(MDNS_NAME)) {
      MDNS.addService("http", "tcp", 80);
      LOG_INFO("wifi", "mDNS ready host=openhaldex.local");
      return;
    }
  }
  LOG_WARN("wifi", "mDNS start failed");
}

// AP-side DNS responder helps AP clients resolve openhaldex.local reliably.
static void startApDns() {
  if ((WiFi.getMode() & WIFI_MODE_AP) == 0) {
    if (g_ap_dns_running) {
      g_ap_dns.stop();
      g_ap_dns_running = false;
    }
    return;
  }

  IPAddress ap_ip = WiFi.softAPIP();
  if (ap_ip == IPAddress(0, 0, 0, 0)) {
    return;
  }

  g_ap_dns.stop();
  g_ap_dns.start(53, "*", ap_ip);
  g_ap_dns_running = true;
  LOG_INFO("wifi", "AP DNS ready ip=%s", ap_ip.toString().c_str());
}

// Start AP, but only restart it when AP password changed.
static void startApInterface() {
  String ap_pass = apPasswordForSoftAp();

  wifi_mode_t mode = WiFi.getMode();
  if ((mode & WIFI_MODE_AP) == 0) {
    WiFi.mode((mode & WIFI_MODE_STA) ? WIFI_AP_STA : WIFI_AP);
  }

  bool pass_changed = (!g_ap_started || ap_pass != g_ap_password_applied);
  if (pass_changed) {
    const char* pass_ptr = ap_pass.length() > 0 ? ap_pass.c_str() : nullptr;
    WiFi.softAPdisconnect(true);
    delay(50);
    WiFi.softAP(AP_SSID, pass_ptr, 1, false, 4);
    g_ap_started = true;
    g_ap_password_applied = ap_pass;
    LOG_INFO("wifi", "AP started ip=%s secured=%d", WiFi.softAPIP().toString().c_str(), ap_pass.length() > 0 ? 1 : 0);
  }

  startApDns();
}

// Apply STA policy while leaving AP alive:
// - enabled + creds: keep trying to connect/reconnect
// - disabled or no creds: AP only
static void applyStaPolicy(bool force_connect_attempt) {
  String ssid;
  String pass;
  bool sta_enabled = storageGetWifiStaEnabled();
  bool have_creds = storageGetWifiCreds(ssid, pass) && ssid.length() > 0;

  if (!sta_enabled || !have_creds) {
    g_sta_last_attempt_ms = 0;
    g_sta_last_attempt_ssid = "";

    if ((WiFi.getMode() & WIFI_MODE_STA) != 0) {
      WiFi.disconnect(false, true);
      WiFi.setAutoReconnect(false);
      WiFi.mode(WIFI_AP);
      startApDns();
      startMdns();
    }
    return;
  }

  if (WiFi.getMode() != WIFI_AP_STA) {
    WiFi.mode(WIFI_AP_STA);
    startApDns();
    startMdns();
  }

  WiFi.setAutoReconnect(true);
  // Keep DHCP but force resolver selection for hotspot edge cases.
  WiFi.config(INADDR_NONE, INADDR_NONE, INADDR_NONE, IPAddress(8, 8, 8, 8), IPAddress(1, 1, 1, 1));

  if (!force_connect_attempt && WiFi.status() == WL_CONNECTED && WiFi.SSID() == ssid) {
    return;
  }

  uint32_t now = millis();
  bool ssid_changed = (ssid != g_sta_last_attempt_ssid);
  bool retry_due = (g_sta_last_attempt_ms == 0) || ((now - g_sta_last_attempt_ms) >= WIFI_STA_RETRY_MS);
  if (!force_connect_attempt && !ssid_changed && !retry_due) {
    return;
  }

  LOG_INFO("wifi", "STA connect attempt ssid=%s", ssid.c_str());
  WiFi.begin(ssid.c_str(), pass.c_str());
  g_sta_last_attempt_ms = now;
  g_sta_last_attempt_ssid = ssid;
}

// Boot/apply-time setup. AP first, then STA policy.
static void wifiStart() {
  WiFi.setSleep(false);
  startApInterface();

  String ssid;
  String pass;
  bool sta_enabled = storageGetWifiStaEnabled();
  bool have_creds = storageGetWifiCreds(ssid, pass) && ssid.length() > 0;

  if (!have_creds) {
    LOG_WARN("wifi", "No STA credentials, AP only");
  } else if (!sta_enabled) {
    LOG_WARN("wifi", "STA disabled, AP only");
  } else {
    LOG_INFO("wifi", "STA enabled; background connect active ssid=%s", ssid.c_str());
  }

  applyStaPolicy(sta_enabled && have_creds);
  startMdns();
}

// Keep STA searching/reconnecting while enabled.
static void wifiStaMaintainTask(void* arg) {
  (void)arg;
  bool last_connected = false;
  for (;;) {
    applyStaPolicy(false);

    bool now_connected = (WiFi.status() == WL_CONNECTED);
    if (now_connected != last_connected) {
      if (now_connected) {
        LOG_INFO("wifi", "STA connected ip=%s", WiFi.localIP().toString().c_str());
        startMdns();
      } else {
        LOG_WARN("wifi", "STA disconnected");
      }
      last_connected = now_connected;
    }

    vTaskDelay(pdMS_TO_TICKS(5000));
  }
}

// Runtime apply path used by /api/wifi settings updates.
static void wifiApplyTask(void* arg) {
  (void)arg;
  wifiStart();
  vTaskDelete(nullptr);
}

void wifiApplySettings() {
  xTaskCreatePinnedToCore(wifiApplyTask, "wifiApply", 4096, nullptr, 1, nullptr, OH_APP_TASK_CORE);
}

#else  // !OH_ENABLE_WEB

// One-board build: the iOS app (over BLE) replaces the web UI, so Wi-Fi is only
// a client of the MMI's hotspot (for the gauge link). No AP, DNS, mDNS, web
// server or internet update check. With no hotspot configured (or joining
// disabled) Wi-Fi stays completely off, which frees the most internal RAM.
static const uint32_t WIFI_STA_RETRY_MS = 10000;
static uint32_t g_sta_last_attempt_ms = 0;
static String g_sta_last_attempt_ssid;
static bool g_wifi_on = false;

bool wifiInternetOk() {
  return false;
}

static void applyStaPolicy(bool force_connect_attempt) {
  String ssid;
  String pass;
  const bool sta_enabled = storageGetWifiStaEnabled();
  const bool have_creds = storageGetWifiCreds(ssid, pass) && ssid.length() > 0;

  if (!sta_enabled || !have_creds) {
    g_sta_last_attempt_ms = 0;
    g_sta_last_attempt_ssid = "";
    if (g_wifi_on) {
      WiFi.disconnect(true, true);
      WiFi.mode(WIFI_OFF);
      g_wifi_on = false;
      LOG_INFO("wifi", "Wi-Fi off (no hotspot configured or joining disabled)");
    }
    return;
  }

  if (!g_wifi_on) {
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.setAutoReconnect(true);
    g_wifi_on = true;
    force_connect_attempt = true;
  }

  if (!force_connect_attempt && WiFi.status() == WL_CONNECTED && WiFi.SSID() == ssid) {
    return;
  }
  const uint32_t now = millis();
  const bool ssid_changed = (ssid != g_sta_last_attempt_ssid);
  const bool retry_due = (g_sta_last_attempt_ms == 0) || ((now - g_sta_last_attempt_ms) >= WIFI_STA_RETRY_MS);
  if (!force_connect_attempt && !ssid_changed && !retry_due) {
    return;
  }
  LOG_INFO("wifi", "STA connect attempt ssid=%s", ssid.c_str());
  WiFi.begin(ssid.c_str(), pass.c_str());
  g_sta_last_attempt_ms = now;
  g_sta_last_attempt_ssid = ssid;
}

static void wifiStart() {
  applyStaPolicy(true);
}

static void wifiStaMaintainTask(void* arg) {
  (void)arg;
  bool last_connected = false;
  for (;;) {
    applyStaPolicy(false);
    const bool now_connected = g_wifi_on && (WiFi.status() == WL_CONNECTED);
    if (now_connected != last_connected) {
      if (now_connected) {
        LOG_INFO("wifi", "STA connected ip=%s", WiFi.localIP().toString().c_str());
      } else {
        LOG_WARN("wifi", "STA disconnected");
      }
      last_connected = now_connected;
    }
    vTaskDelay(pdMS_TO_TICKS(5000));
  }
}

// Called by /api/wifi (now reached from the app over BLE).
void wifiApplySettings() {
  // Runs on the BLE API task; applyStaPolicy is cheap and non-blocking.
  applyStaPolicy(true);
}

#endif  // OH_ENABLE_WEB

void setup() {

  Serial.begin(115200);
  // General allocations over 256 B go to the (otherwise idle) 8 MB PSRAM.
  heap_caps_malloc_extmem_enable(256);
  LOG_INFO("system", "OpenHaldex S3 starting");

  mappedInputSignalsInit();
  modeTriggerInit();
  dashboardSignalsInit();
  powerInitBootState();
  powerLoadBootSettings();
  if (!powerBootProbeOrSleep()) {
    return;
  }

  // Bring CAN online before filesystem, network, and web services.
  canInit();

  storageInit();
  filelogInit();
  storageLoad();
  diagUdsInit();
  diagUdsHaldexTempPollInit();
  LOG_INFO("system", "Storage loaded and logger active");

  // BLE claims its controller memory before tasks and Wi-Fi fragment the heap.
  racechronoBleInit();

  tasksInit();
  powerStartMonitor();

  wifiStart();
#if OH_ENABLE_RC3
  racechronoWifiInit();
#endif

  xTaskCreatePinnedToCore(wifiStaMaintainTask, "wifiStaMaintain", 2560, nullptr, 1, nullptr, OH_APP_TASK_CORE);
#if OH_ENABLE_WEB
  updateInit();
  xTaskCreatePinnedToCore(internetCheckTask, "internetCheck", 4096, nullptr, 1, nullptr, OH_APP_TASK_CORE);

  webInit(server);
  setupApi(server);
  server.begin();
#endif
}

#if OH_MEM_DIAG
static void memDiagTick() {
  static uint32_t last_ms = 0;
  if (millis() - last_ms < 5000) {
    return;
  }
  last_ms = millis();
  Serial.printf("[MEM] up=%lus free_internal=%u largest=%u min_ever=%u free_psram=%u\n",
                (unsigned long)(millis() / 1000),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}
#endif

void loop() {
#if OH_MEM_DIAG
  memDiagTick();
#endif
#if OH_ENABLE_WEB
  if (g_ap_dns_running) {
    g_ap_dns.processNextRequest();
  }
#endif
  delay(10);
}
