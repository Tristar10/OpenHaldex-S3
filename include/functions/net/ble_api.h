#pragma once

class NimBLEServer;

// BLE transport for the JSON API (the iOS app's replacement for the web UI).
//
// Service 4f480001-0000-4c44-8000-4f70656e4844
//   RX 4f480002-...  write / write-without-response: request fragments
//   TX 4f480003-...  notify: response fragments
//
// Every fragment is [flags][payload...]; flags bit0 = first fragment,
// bit1 = last fragment. A reassembled message is "<header>\n<body>":
//   request header : "<id> <GET|POST> <path>[?query]"
//   response header: "<id> <http status> <content type>"
// Requests are handled one at a time, in order.
bool bleApiAttach(NimBLEServer* server);
void bleApiOnDisconnect(unsigned short conn_handle);
