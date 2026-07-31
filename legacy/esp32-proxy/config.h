#pragma once

// MR-Proxy — dual-role BLE bridge
// Central → LG Magic Remote | Peripheral (custom GATT) → macOS

static const char *kProxyName = "MR-Proxy";
static const char *kRemoteName = "LGE MR25GA";

// Custom GATT (Mac)
// Service  6D520001-4D52-3235-4741-425249444745
// Event    6D520010-…  Notify  binary BridgePacket
// Status   6D520003-…  Notify/Read  uint8 state
// Command  6D520012-…  Write   calib / sens / voice…

#define PROXY_SVC_UUID   "6D520001-4D52-3235-4741-425249444745"
#define PROXY_EVT_UUID   "6D520010-4D52-3235-4741-425249444745"
#define PROXY_STS_UUID   "6D520003-4D52-3235-4741-425249444745"
#define PROXY_CMD_UUID   "6D520012-4D52-3235-4741-425249444745"

// Remote vendor
#define REMOTE_SVC_D1FF  "0000D1FF-3C17-D293-8E48-14FE2E4DA212"
#define REMOTE_SVC_D0FF  "0000D0FF-3C17-D293-8E48-14FE2E4DA212"

#define EVENT_QUEUE_LEN  64
#define SCAN_BURST_SEC   3
