#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <driver/twai.h>

// Experimental: checks whether the engine ECU answers diagnostic requests sent
// from the chassis-side bus (i.e. whether the gateway routes them). Sends a few
// read-only RPM requests (OBD-II mode 01 PID 0x0C, UDS 0x22 F40C) over 11-bit
// and 29-bit addressing and records every reply.

void engineProbeInit();

// Called from the chassis receive loop for every frame. Never consumes frames.
void engineProbeObserveChassisFrame(const twai_message_t& frame);

// Blocking; runs all variants (~1.5 s total) and writes a report into out.
void engineProbeRun(JsonObject out);
