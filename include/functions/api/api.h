#pragma once

#include <Arduino.h>

#ifndef OH_ENABLE_WEB
#define OH_ENABLE_WEB 1
#endif

struct ApiResponse {
  int code = 500;
  String type;
  String body;
};

// Runs one API request through the same handlers the web UI uses. Used by the
// BLE API bridge (functions/net/ble_api). `query` is "a=1&b=2" (URL-encoded).
bool apiDispatch(const String& method, const String& path, const String& query, const String& body,
                 ApiResponse& out);

#if OH_ENABLE_WEB
#include <ESPAsyncWebServer.h>
void setupApi(AsyncWebServer& server);
#endif
