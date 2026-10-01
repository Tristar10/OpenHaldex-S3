#pragma once

#include <driver/twai.h>

// Starts the RaceChrono BLE DIY service. BLE telemetry runs independently from
// the CAN bridge and is intentionally best-effort: a full telemetry queue drops
// data instead of delaying chassis-to-Haldex traffic.
void racechronoBleInit();

// Offers an unmodified chassis CAN frame to the RaceChrono filter. This call is
// non-blocking and performs no BLE work on the CAN task/core.
void racechronoBleSubmitChassisFrame(const twai_message_t& frame);
