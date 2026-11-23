#pragma once

#include <stdint.h>

// Sends live values to an Audi MMI (MIB2 head unit) over the MMI's own Wi-Fi
// hotspot, for display on the virtual cockpit. OpenHaldex joins the hotspot
// with its existing STA settings (Setup > Wi-Fi) and keeps its own AP running.
// UDP "TTG1" datagrams go to the STA gateway (the MMI) on port 49160; the head
// unit answers each with "TTA1". See docs/MMI_LINK.md.
//
// No task of its own: mmiLinkTick() is called from loop() and rate-limits
// itself. With no STA connection it only checks every 500 ms; until the head
// unit answers it sends one probe per second, so a home router on the STA
// side never gets the full 20 Hz stream.
void mmiLinkInit();
void mmiLinkTick();

struct MmiLinkStats {
  bool staConnected;
  bool linked;        // ack seen in the last 3 s
  uint32_t gateway;   // STA gateway, network order as in IPAddress
  uint32_t sent;
  uint32_t acks;
  uint32_t rttLastMs;
  uint32_t rttMaxMs;
  uint32_t huRx;      // datagrams the head unit says it received
  uint32_t huLost;    // gaps the head unit counted
  uint32_t lastAckAgeMs;
};

void mmiLinkGetStats(MmiLinkStats& out);
