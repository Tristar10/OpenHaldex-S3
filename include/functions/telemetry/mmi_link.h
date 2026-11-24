#pragma once

#include <Arduino.h>

#include <stdint.h>

// Sends live values to an Audi MMI (MIB2 head unit) over the MMI's own Wi-Fi
// hotspot, for display on the virtual cockpit. OpenHaldex joins the hotspot
// with its STA settings (app: More > Wi-Fi). In the one-board build
// (OH_ENABLE_WEB=0) there is no AP; Wi-Fi exists only for this link.
// UDP "TTG1" datagrams go to the STA gateway (the MMI); the head unit answers
// each with "TTA1". Its port is discovered in 49153-49162 (the range the stock
// firewall opens, shared with wireless CarPlay). See docs/MMI_LINK.md.
//
// No task of its own: mmiLinkTick() is called from loop() and rate-limits
// itself. With no STA connection it only checks every 500 ms; until the head
// unit answers it sends a probe every 250 ms, each to the next port in the
// range, so a home router on the STA side never gets the full 20 Hz stream.
void mmiLinkInit();
void mmiLinkTick();
// Bench only: send to this IPv4 address instead of the STA gateway. Empty
// string clears it. Returns false for an invalid address.
bool mmiLinkSetTarget(const String& ip);

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
  uint16_t port;      // head unit UDP port in use / being probed
};

void mmiLinkGetStats(MmiLinkStats& out);
