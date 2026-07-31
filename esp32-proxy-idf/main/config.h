#pragma once

#define PROXY_NAME       "MR-Proxy"
#define REMOTE_NAME      "LGE MR25GA"

#define EVENT_QUEUE_LEN  64
#define SCAN_BURST_MS    5000
#define SCAN_INTERVAL    80
#define SCAN_WINDOW      48

/* Maximum idle wait for the BLE owner loop before checking work again. */
#ifndef BLE_CORE_IDLE_WAIT_MS
#define BLE_CORE_IDLE_WAIT_MS 2
#endif

/* Mac↔Proxy: require encrypted link (Just Works bond) before CMD write / ready.
 * Disable (0) for debug only — nearby device can write CMD. */
#ifndef PROXY_REQUIRE_MAC_ENC
#define PROXY_REQUIRE_MAC_ENC 1
#endif

/* Notify button/status: max retry count + backoff on ATT fail. */
#ifndef BRIDGE_NOTIFY_MAX_RETRY
#define BRIDGE_NOTIFY_MAX_RETRY 5
#endif

/* Motion coalesce: latency-first — clamp backlog, no unbounded history. */
#ifndef MOTION_ACCUM_MAX
#define MOTION_ACCUM_MAX 64
#endif

/* LG vendor service 0000D1FF-3C17-D293-8E48-14FE2E4DA212 (LE bytes) */
#define REMOTE_D1FF_UUID128 \
  0x12, 0xa2, 0x4d, 0x2e, 0xfe, 0x14, 0x48, 0x8e, \
  0x93, 0xd2, 0x17, 0x3c, 0xff, 0xd1, 0x00, 0x00

/* 128-bit UUID bytes (LE) for 6D520001-4D52-3235-4741-425249444745 */
#define PROXY_SVC_UUID128 \
  0x45, 0x47, 0x44, 0x49, 0x52, 0x42, 0x41, 0x47, 0x35, 0x32, 0x52, 0x4d, 0x01, 0x00, 0x52, 0x6d
#define PROXY_EVT_UUID128 \
  0x45, 0x47, 0x44, 0x49, 0x52, 0x42, 0x41, 0x47, 0x35, 0x32, 0x52, 0x4d, 0x10, 0x00, 0x52, 0x6d
#define PROXY_STS_UUID128 \
  0x45, 0x47, 0x44, 0x49, 0x52, 0x42, 0x41, 0x47, 0x35, 0x32, 0x52, 0x4d, 0x03, 0x00, 0x52, 0x6d
#define PROXY_CMD_UUID128 \
  0x45, 0x47, 0x44, 0x49, 0x52, 0x42, 0x41, 0x47, 0x35, 0x32, 0x52, 0x4d, 0x12, 0x00, 0x52, 0x6d
