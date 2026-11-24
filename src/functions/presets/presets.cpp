#include "functions/presets/presets.h"

#include <LittleFS.h>
#include <esp_heap_caps.h>

#include "functions/api/api.h"
#include "functions/config/config.h"
#include "functions/core/state.h"
#include "functions/storage/filelog.h"
#include "functions/storage/storage.h"

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

namespace {

constexpr char kPresetsFile[] = "/presets.json";

struct Preset {
  PresetInfo info;
  MapTable* map;  // PSRAM, null when info.map is empty or failed to load
};

Preset g_presets[kPresetMax];
uint8_t g_count = 0;
uint16_t g_version = 0;
SemaphoreHandle_t g_mutex = nullptr;

void lock() {
  if (!g_mutex) {
    g_mutex = xSemaphoreCreateRecursiveMutex();
  }
  xSemaphoreTakeRecursive(g_mutex, portMAX_DELAY);
}

void unlock() { xSemaphoreGiveRecursive(g_mutex); }

bool parseMode(const char* name, uint8_t& out) {
  if (!name) {
    return false;
  }
  String want(name);
  want.toUpperCase();
  for (int m = 0; m < (int)openhaldex_mode_t_MAX; m++) {
    if (m == MODE_MANUAL) continue;  // needs a setpoint; MMI-only
    if (want == get_openhaldex_mode_string((openhaldex_mode_t)m)) {
      out = (uint8_t)m;
      return true;
    }
  }
  return false;
}

// CRC-16/CCITT over the parts the MMI shows/acts on, so the version is stable
// across reboots and changes whenever the catalog does.
uint16_t crc16(uint16_t crc, const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    crc ^= (uint16_t)data[i] << 8;
    for (int b = 0; b < 8; b++) {
      crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
  }
  return crc;
}

void computeVersion() {
  uint16_t crc = 0xFFFF;
  for (uint8_t i = 0; i < g_count; i++) {
    const PresetInfo& p = g_presets[i].info;
    crc = crc16(crc, &p.id, 1);
    crc = crc16(crc, (const uint8_t*)p.name, strlen(p.name));
    crc = crc16(crc, &p.mode, 1);
    crc = crc16(crc, (const uint8_t*)p.map, strlen(p.map));
  }
  g_version = crc == 0 ? 1 : crc;  // 0 is never a valid version
}

void freeMaps() {
  for (uint8_t i = 0; i < kPresetMax; i++) {
    if (g_presets[i].map) {
      heap_caps_free(g_presets[i].map);
      g_presets[i].map = nullptr;
    }
  }
}

void addPreset(uint8_t id, const char* name, uint8_t mode, const char* map, int16_t disable_throttle = -1,
               int16_t disable_speed = -1, float release = -1.0f) {
  if (g_count >= kPresetMax) {
    return;
  }
  Preset& p = g_presets[g_count++];
  p = {};
  p.info.id = id;
  strlcpy(p.info.name, name, sizeof(p.info.name));
  p.info.mode = mode;
  strlcpy(p.info.map, map ? map : "", sizeof(p.info.map));
  p.info.disableThrottle = disable_throttle;
  p.info.disableSpeed = disable_speed;
  p.info.releaseRate = release;
}

void loadDefaults() {
  g_count = 0;
  // Proposed defaults (not yet chosen by the user); override with /presets.json.
  addPreset(1, "Street", MODE_STOCK, "");
  addPreset(2, "Autocross", MODE_MAP, "/maps/aggressive.txt");
  addPreset(3, "Launch", MODE_5050, "");
  addPreset(4, "Wet", MODE_MAP, "/maps/conservative.txt");
  addPreset(5, "FWD", MODE_FWD, "");
}

// Fills the catalog from a {"presets":[...]} document. Returns false with an
// error message (catalog untouched) if anything is invalid.
bool parseCatalog(JsonVariantConst doc, Preset* out, uint8_t& count, String& error) {
  JsonArrayConst arr = doc["presets"].as<JsonArrayConst>();
  if (arr.isNull() || arr.size() == 0) {
    error = "presets must be a non-empty array";
    return false;
  }
  if (arr.size() > kPresetMax) {
    error = "too many presets (max 8)";
    return false;
  }
  count = 0;
  for (JsonObjectConst o : arr) {
    Preset p = {};
    const int id = o["id"] | -1;
    if (id < 0 || id >= kPresetNone) {
      error = "id must be 0..254";
      return false;
    }
    for (uint8_t i = 0; i < count; i++) {
      if (out[i].info.id == id) {
        error = "duplicate id";
        return false;
      }
    }
    const char* name = o["name"] | "";
    if (strlen(name) == 0 || strlen(name) > kPresetNameMax) {
      error = "name must be 1..16 characters";
      return false;
    }
    for (const char* c = name; *c; c++) {
      if ((unsigned char)*c < 0x20 || (unsigned char)*c > 0x7E) {
        error = "names must be plain ASCII (MMI font)";
        return false;
      }
    }
    uint8_t mode = 0;
    if (!parseMode(o["mode"] | "", mode)) {
      error = String("invalid mode for ") + name;
      return false;
    }
    const char* map = o["map"] | "";
    if (mode == MODE_MAP && strlen(map) == 0) {
      error = String("MAP preset needs a map file: ") + name;
      return false;
    }
    p.info.id = (uint8_t)id;
    strlcpy(p.info.name, name, sizeof(p.info.name));
    p.info.mode = mode;
    strlcpy(p.info.map, map, sizeof(p.info.map));
    p.info.disableThrottle = (int16_t)constrain((int)(o["disableThrottle"] | -1), -1, 100);
    p.info.disableSpeed = (int16_t)constrain((int)(o["disableSpeed"] | -1), -1, 300);
    p.info.releaseRate = o["lockReleaseRatePctPerSec"] | -1.0f;
    out[count++] = p;
  }
  return true;
}

// Parse every referenced map into PSRAM (boot / catalog change only).
void preloadMaps() {
  for (uint8_t i = 0; i < g_count; i++) {
    Preset& p = g_presets[i];
    p.info.mapLoaded = false;
    if (strlen(p.info.map) == 0) {
      continue;
    }
    MapTable* m = (MapTable*)heap_caps_malloc(sizeof(MapTable), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!m) {
      m = (MapTable*)malloc(sizeof(MapTable));
    }
    if (m && storageReadMapFile(p.info.map, *m)) {
      p.map = m;
      p.info.mapLoaded = true;
    } else {
      if (m) heap_caps_free(m);
      LOG_WARN("presets", "Preset %s: map %s failed to load", p.info.name, p.info.map);
    }
  }
}

void loadCatalog() {
  freeMaps();
  bool from_file = false;
  if (storageFsReady() && LittleFS.exists(kPresetsFile)) {
    File f = LittleFS.open(kPresetsFile, "r");
    if (f) {
      JsonDocument doc;
      const DeserializationError err = deserializeJson(doc, f);
      f.close();
      String error;
      Preset parsed[kPresetMax];
      uint8_t count = 0;
      if (!err && parseCatalog(doc, parsed, count, error)) {
        for (uint8_t i = 0; i < count; i++) g_presets[i] = parsed[i];
        g_count = count;
        from_file = true;
      } else {
        LOG_WARN("presets", "Ignoring %s (%s); using defaults", kPresetsFile, err ? err.c_str() : error.c_str());
      }
    }
  }
  if (!from_file) {
    loadDefaults();
  }
  preloadMaps();
  computeVersion();
  LOG_INFO("presets", "%u presets (%s) version=0x%04X", (unsigned)g_count, from_file ? "file" : "defaults",
           (unsigned)g_version);
}

const Preset* findById(uint8_t id) {
  for (uint8_t i = 0; i < g_count; i++) {
    if (g_presets[i].info.id == id) {
      return &g_presets[i];
    }
  }
  return nullptr;
}

bool matches(const Preset& p) {
  if (state.mode != (openhaldex_mode_t)p.info.mode) return false;
  if (p.info.disableThrottle >= 0 && disableThrottle != p.info.disableThrottle) return false;
  if (p.info.disableSpeed >= 0 && disableSpeed != p.info.disableSpeed) return false;
  if (p.info.releaseRate >= 0 && fabsf(lockReleaseRatePctPerSec - p.info.releaseRate) > 0.01f) return false;
  if (p.map) {
    MapTable live;
    mapTableSnapshot(live);
    if (!mapTableEquals(live, *p.map)) return false;
  }
  return true;
}

}  // namespace

void presetsInit() {
  lock();
  loadCatalog();
  // Applying a preset swaps the map in RAM only (no flash write while
  // driving), so after a restart the stored map is whatever was loaded before.
  // Re-apply the active preset's map when the restored mode still matches it.
  const Preset* p = activePresetId != kPresetNone ? findById(activePresetId) : nullptr;
  const bool restore = p && p->map && state.mode == (openhaldex_mode_t)p->info.mode;
  if (restore) mapTableApply(*p->map);
  unlock();
  if (restore) LOG_INFO("presets", "restored map of active preset %u", (unsigned)activePresetId);
}

uint16_t presetsCatalogVersion() { return g_version; }

uint8_t presetsCount() { return g_count; }

bool presetsGet(uint8_t index, PresetInfo& out) {
  lock();
  const bool ok = index < g_count;
  if (ok) out = g_presets[index].info;
  unlock();
  return ok;
}

uint8_t presetsActiveId() {
  lock();
  uint8_t id = kPresetNone;
  const Preset* p = activePresetId != kPresetNone ? findById(activePresetId) : nullptr;
  if (p && matches(*p)) id = p->info.id;
  unlock();
  return id;
}

PresetResult presetsApply(uint8_t id, int32_t catalog_version) {
  lock();
  PresetResult result = PRESET_OK;
  const Preset* p = nullptr;
  if (catalog_version >= 0 && (uint16_t)catalog_version != g_version) {
    result = PRESET_BAD_VERSION;
  } else if (!(p = findById(id))) {
    result = PRESET_UNKNOWN_ID;
  } else if (haldexLearnActive) {
    result = PRESET_REFUSED_LEARN;
  } else if (apiCanviewCaptureActive()) {
    result = PRESET_REFUSED_CAPTURE;
  } else if (strlen(p->info.map) > 0 && !p->map) {
    result = PRESET_MAP_MISSING;
  }

  if (result == PRESET_OK) {
    // Same effect as the mode buttons (applyRuntimeMode), plus the bundle.
    if (p->map) mapTableApply(*p->map);
    if (p->info.disableThrottle >= 0) disableThrottle = (uint8_t)p->info.disableThrottle;
    if (p->info.disableSpeed >= 0) disableSpeed = (uint16_t)p->info.disableSpeed;
    if (p->info.releaseRate >= 0) lockReleaseRatePctPerSec = p->info.releaseRate;
    state.mode = (openhaldex_mode_t)p->info.mode;
    disableController = (state.mode == MODE_STOCK);
    lastMode = (uint8_t)state.mode;
    activePresetId = p->info.id;
    storageMarkDirty();  // persisted later by writeEEP; no flash write here
  }
  const char* name = p ? p->info.name : "?";
  unlock();

  if (result == PRESET_OK) {
    filelogLogEvent("preset", String("applied ") + name);
  } else {
    LOG_WARN("presets", "Apply id=%u refused: %s", (unsigned)id, presetsResultName(result));
  }
  return result;
}

// MMI SET_MODE / SET_LOCK: same guards as a preset, same effect as the
// app's mode buttons; the active preset clears.
static PresetResult guardManualChange() {
  if (haldexLearnActive) return PRESET_REFUSED_LEARN;
  if (apiCanviewCaptureActive()) return PRESET_REFUSED_CAPTURE;
  return PRESET_OK;
}

static void setModeLocked(openhaldex_mode_t mode) {
  state.mode = mode;
  disableController = (mode == MODE_STOCK);
  lastMode = (uint8_t)mode;
  activePresetId = kPresetNone;
  storageMarkDirty();
}

PresetResult presetsSetMode(uint8_t mode) {
  if (mode >= openhaldex_mode_t_MAX || mode == MODE_MANUAL) return PRESET_OUT_OF_RANGE;
  lock();
  const PresetResult result = guardManualChange();
  if (result == PRESET_OK) setModeLocked((openhaldex_mode_t)mode);
  unlock();
  if (result == PRESET_OK) {
    filelogLogEvent("mode", String("MMI set ") + get_openhaldex_mode_string((openhaldex_mode_t)mode));
  }
  return result;
}

PresetResult presetsSetManualLock(uint8_t pct) {
  if (pct > 100) return PRESET_OUT_OF_RANGE;
  lock();
  const PresetResult result = guardManualChange();
  if (result == PRESET_OK) {
    // Raising the lock is immediate; lowering it follows the release ramp
    // in calcs (smooth_lock_release), as for every mode change.
    manualLockPct = pct;
    setModeLocked(MODE_MANUAL);
  }
  unlock();
  if (result == PRESET_OK) {
    filelogLogEvent("mode", String("MMI manual lock ") + String(pct) + "%");
  }
  return result;
}

const char* presetsResultName(PresetResult result) {
  switch (result) {
    case PRESET_OK: return "ok";
    case PRESET_BAD_VERSION: return "catalog version mismatch";
    case PRESET_UNKNOWN_ID: return "unknown preset";
    case PRESET_REFUSED_LEARN: return "calibration running";
    case PRESET_REFUSED_CAPTURE: return "CAN View capture active";
    case PRESET_MAP_MISSING: return "preset map missing";
    case PRESET_OUT_OF_RANGE: return "value out of range";
  }
  return "error";
}

void presetsWriteJson(JsonObject out) {
  lock();
  out["version"] = g_version;
  JsonArray arr = out["presets"].to<JsonArray>();
  for (uint8_t i = 0; i < g_count; i++) {
    const PresetInfo& p = g_presets[i].info;
    JsonObject o = arr.add<JsonObject>();
    o["id"] = p.id;
    o["name"] = p.name;
    o["mode"] = get_openhaldex_mode_string((openhaldex_mode_t)p.mode);
    o["map"] = p.map;
    o["mapLoaded"] = p.mapLoaded;
    o["disableThrottle"] = p.disableThrottle;
    o["disableSpeed"] = p.disableSpeed;
    o["lockReleaseRatePctPerSec"] = p.releaseRate;
  }
  out["custom"] = storageFsReady() && LittleFS.exists(kPresetsFile);
  unlock();
  out["active"] = presetsActiveId();
}

bool presetsSaveJson(const String& body, String& error) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) {
    error = "invalid json";
    return false;
  }
  Preset parsed[kPresetMax];
  uint8_t count = 0;
  if (!parseCatalog(doc, parsed, count, error)) {
    return false;
  }
  if (!storageFsReady()) {
    error = "filesystem not ready";
    return false;
  }
  // Write exactly the validated catalog back out (normalised).
  JsonDocument outDoc;
  JsonArray arr = outDoc["presets"].to<JsonArray>();
  for (uint8_t i = 0; i < count; i++) {
    const PresetInfo& p = parsed[i].info;
    JsonObject o = arr.add<JsonObject>();
    o["id"] = p.id;
    o["name"] = p.name;
    o["mode"] = get_openhaldex_mode_string((openhaldex_mode_t)p.mode);
    o["map"] = p.map;
    if (p.disableThrottle >= 0) o["disableThrottle"] = p.disableThrottle;
    if (p.disableSpeed >= 0) o["disableSpeed"] = p.disableSpeed;
    if (p.releaseRate >= 0) o["lockReleaseRatePctPerSec"] = p.releaseRate;
  }
  File f = LittleFS.open(kPresetsFile, "w");
  if (!f) {
    error = "write failed";
    return false;
  }
  serializeJson(outDoc, f);
  f.close();

  lock();
  loadCatalog();
  unlock();
  filelogLogEvent("preset", String("catalog saved count=") + String(count));
  return true;
}

void presetsResetToDefaults() {
  if (storageFsReady() && LittleFS.exists(kPresetsFile)) {
    LittleFS.remove(kPresetsFile);
  }
  lock();
  loadCatalog();
  unlock();
}
