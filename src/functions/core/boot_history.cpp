#include "functions/core/boot_history.h"

#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_attr.h>
#include <esp_heap_caps.h>
#include <esp_system.h>

#include "functions/core/state.h"
#include "functions/storage/filelog.h"
#include "functions/telemetry/mmi_link.h"

namespace {

constexpr uint32_t kMagic = 0x4F48424Eu;  // "OHBN"
constexpr uint8_t kRing = 12;

enum : uint8_t {
  F_WIFI = 0x01,     // STA connected
  F_MMI = 0x02,      // MMI link up
  F_CHASSIS = 0x04,  // chassis CAN frame in the last second
  F_HALDEX = 0x08,   // Haldex CAN frame in the last second
};

// Survives every reset except a power cut (then magic is garbage).
struct Breadcrumb {
  uint32_t magic;
  uint32_t uptime_s;
  uint32_t min_heap;   // lowest free internal heap seen this boot
  uint32_t free_heap;  // free internal heap at the last update
  uint8_t flags;
};
RTC_NOINIT_ATTR Breadcrumb g_crumb;

struct Entry {
  uint32_t boot;       // boot counter
  uint8_t reason;      // esp_reset_reason_t
  uint8_t flags;       // previous boot's last flags (crumb valid only)
  uint8_t crumb;       // 1 if the previous boot's breadcrumb survived
  uint8_t pad;
  uint32_t prev_uptime_s;
  uint32_t prev_min_heap;
  uint32_t prev_free_heap;
};

Entry g_ring[kRing] = {};
uint32_t g_boot_count = 0;

const char* reasonName(uint8_t r) {
  switch ((esp_reset_reason_t)r) {
  case ESP_RST_POWERON: return "power-on";
  case ESP_RST_EXT: return "external";
  case ESP_RST_SW: return "software";
  case ESP_RST_PANIC: return "panic";
  case ESP_RST_INT_WDT: return "interrupt watchdog";
  case ESP_RST_TASK_WDT: return "task watchdog";
  case ESP_RST_WDT: return "watchdog";
  case ESP_RST_DEEPSLEEP: return "deep-sleep wake";
  case ESP_RST_BROWNOUT: return "brownout";
  case ESP_RST_SDIO: return "sdio";
  case ESP_RST_USB: return "usb";
  case ESP_RST_JTAG: return "jtag";
  default: return "unknown";
  }
}

bool isCrash(uint8_t r) {
  return r == ESP_RST_PANIC || r == ESP_RST_INT_WDT || r == ESP_RST_TASK_WDT || r == ESP_RST_WDT ||
         r == ESP_RST_BROWNOUT;
}

}  // namespace

void bootHistoryInit() {
  const uint8_t reason = (uint8_t)esp_reset_reason();
  const bool crumb_ok = g_crumb.magic == kMagic && reason != ESP_RST_POWERON;

  // Parked-sleep wakes are routine (and may be frequent): don't spend NVS
  // writes or ring slots on them.
  Preferences pref;
  if (reason == ESP_RST_DEEPSLEEP && pref.begin("boothist", true)) {
    g_boot_count = pref.getUInt("count", 0);
    pref.getBytes("ring", g_ring, sizeof(g_ring));
    pref.end();
  }
  if (reason != ESP_RST_DEEPSLEEP && pref.begin("boothist", false)) {
    g_boot_count = pref.getUInt("count", 0) + 1;
    pref.getBytes("ring", g_ring, sizeof(g_ring));
    memmove(&g_ring[1], &g_ring[0], sizeof(Entry) * (kRing - 1));
    Entry& e = g_ring[0];
    e = {};
    e.boot = g_boot_count;
    e.reason = reason;
    e.crumb = crumb_ok ? 1 : 0;
    if (crumb_ok) {
      e.flags = g_crumb.flags;
      e.prev_uptime_s = g_crumb.uptime_s;
      e.prev_min_heap = g_crumb.min_heap;
      e.prev_free_heap = g_crumb.free_heap;
    }
    pref.putUInt("count", g_boot_count);
    pref.putBytes("ring", g_ring, sizeof(g_ring));
    pref.end();
  }

  Serial.printf("[boot] #%lu reset reason: %s", (unsigned long)g_boot_count, reasonName(reason));
  if (crumb_ok) {
    Serial.printf(" (previous boot ran %lu s, min heap %lu, flags 0x%02x)", (unsigned long)g_crumb.uptime_s,
                  (unsigned long)g_crumb.min_heap, g_crumb.flags);
  }
  Serial.println();

  g_crumb = {};
  g_crumb.magic = kMagic;
  g_crumb.min_heap = UINT32_MAX;
}

void bootHistoryTick() {
  static uint32_t last_ms = 0;
  static bool logged = false;
  const uint32_t now = millis();
  if (now - last_ms < 1000) {
    return;
  }
  last_ms = now;

  // The file log is up by now: record an abnormal previous reset once.
  if (!logged) {
    logged = true;
    const Entry& e = g_ring[0];
    if (isCrash(e.reason)) {
      filelogLogError("boot", String("Reset by ") + reasonName(e.reason) + " after " + String(e.prev_uptime_s) +
                                  " s (min heap " + String(e.prev_min_heap) + ", flags " + String(e.flags) + ")");
    }
  }

  const uint32_t free_heap = heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  uint8_t flags = 0;
  if (WiFi.status() == WL_CONNECTED) flags |= F_WIFI;
  MmiLinkStats mmi;
  mmiLinkGetStats(mmi);
  if (mmi.linked) flags |= F_MMI;
  if (now - (uint32_t)lastCANChassisTick < 1000) flags |= F_CHASSIS;
  if (now - (uint32_t)lastCANHaldexTick < 1000) flags |= F_HALDEX;

  g_crumb.uptime_s = now / 1000;
  g_crumb.free_heap = free_heap;
  if (free_heap < g_crumb.min_heap) g_crumb.min_heap = free_heap;
  g_crumb.flags = flags;
}

void bootHistoryToJson(JsonDocument& doc) {
  doc["bootCount"] = g_boot_count;
  doc["uptimeS"] = millis() / 1000;
  JsonArray arr = doc["boots"].to<JsonArray>();
  for (uint8_t i = 0; i < kRing; i++) {
    const Entry& e = g_ring[i];
    if (e.boot == 0) break;
    JsonObject o = arr.add<JsonObject>();
    o["boot"] = e.boot;
    o["reason"] = reasonName(e.reason);
    o["crash"] = isCrash(e.reason);
    if (e.crumb) {
      o["prevUptimeS"] = e.prev_uptime_s;
      o["prevMinHeap"] = e.prev_min_heap;
      o["prevFreeHeap"] = e.prev_free_heap;
      o["prevWifi"] = (e.flags & F_WIFI) != 0;
      o["prevMmi"] = (e.flags & F_MMI) != 0;
      o["prevChassis"] = (e.flags & F_CHASSIS) != 0;
      o["prevHaldex"] = (e.flags & F_HALDEX) != 0;
    }
  }
}
