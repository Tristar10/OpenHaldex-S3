#pragma once

#include <ArduinoJson.h>
#include <stdint.h>

// Keeps evidence of resets across power cycles. A breadcrumb in RTC memory
// (survives a panic, watchdog or brownout reset, not a power cut) is updated
// once a second; at boot it is combined with esp_reset_reason() and written to
// an NVS ring of the last 12 boots, which the app reads from /api/boots.

// Call first thing in setup().
void bootHistoryInit();
// Call from loop(); updates the breadcrumb about once a second.
void bootHistoryTick();
// Fills {"bootCount", "boots": [...newest first]}.
void bootHistoryToJson(JsonDocument& doc);
