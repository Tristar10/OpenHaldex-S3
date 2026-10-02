#pragma once

// Starts the RaceChrono WiFi telemetry bridge (RC3 DIY protocol over TCP/IP).
// Runs independently from the CAN bridge and WebUI on its own low-priority
// task; a missing or disconnected RaceChrono client never affects
// control-loop or WebUI timing. Call once, after the WiFi AP is up.
void racechronoWifiInit();
