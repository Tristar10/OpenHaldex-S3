#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

// Presets: named bundles the MMI and the app switch between (mode + optional
// map + optional gates). The catalog comes from /presets.json on LittleFS, or
// compiled-in defaults when that file is absent. Every preset's map is parsed
// into PSRAM at load time, so applying a preset does no file I/O and no flash
// write: the map is swapped in atomically (mapTableApply) and the choice is
// persisted lazily by the existing writeEEP/storageSave path.
//
// See docs/PRESETS.md for the JSON format and the MMI protocol (TTP1/TTC1).

constexpr uint8_t kPresetMax = 8;
constexpr uint8_t kPresetNone = 255;
constexpr size_t kPresetNameMax = 16;

enum PresetResult : uint8_t {
  PRESET_OK = 0,
  PRESET_BAD_VERSION = 1,      // caller's catalog version is stale
  PRESET_UNKNOWN_ID = 2,
  PRESET_REFUSED_LEARN = 3,    // Haldex calibration running
  PRESET_REFUSED_CAPTURE = 4,  // CAN View capture holds the controller in a safe state
  PRESET_MAP_MISSING = 5,      // preset references a map that failed to load
};

struct PresetInfo {
  uint8_t id;
  char name[kPresetNameMax + 1];
  uint8_t mode;             // openhaldex_mode_t
  char map[48];             // map file path, empty = keep current map
  bool mapLoaded;
  int16_t disableThrottle;  // -1 = leave unchanged
  int16_t disableSpeed;     // -1 = leave unchanged
  float releaseRate;        // < 0 = leave unchanged
};

// Call after storageLoad() (needs LittleFS and the persisted active id).
void presetsInit();

uint16_t presetsCatalogVersion();
uint8_t presetsCount();
bool presetsGet(uint8_t index, PresetInfo& out);

// Id of the preset the controller currently matches, or kPresetNone if the
// mode/map/gates were changed since (e.g. by a manual mode change).
uint8_t presetsActiveId();

// version < 0 skips the catalog version check (app / API callers).
PresetResult presetsApply(uint8_t id, int32_t catalog_version);
const char* presetsResultName(PresetResult result);

// Full catalog as JSON (for /api/presets).
void presetsWriteJson(JsonObject out);
// Replace the catalog from a JSON body {"presets":[...]}; writes /presets.json.
bool presetsSaveJson(const String& body, String& error);
// Delete /presets.json and go back to the compiled-in defaults.
void presetsResetToDefaults();
