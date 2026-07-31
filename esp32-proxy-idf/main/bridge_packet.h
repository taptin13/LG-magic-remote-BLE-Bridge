#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  PKT_MOTION = 1,
  PKT_BUTTON = 2,
  PKT_BATTERY = 3,
  PKT_STATUS = 4,
};

enum {
  ST_BOOT = 0,
  ST_WAIT_MAC = 1,
  ST_SCAN_REMOTE = 2,
  ST_REMOTE_CONN = 3,
  ST_READY = 4,
  ST_REMOTE_DROP = 5,
};

typedef struct __attribute__((packed)) {
  int16_t dx;
  int16_t dy;
  uint16_t buttons;
  int8_t wheel;
} motion_payload_t;

typedef struct __attribute__((packed)) {
  uint16_t code;
  uint8_t down;
} button_payload_t;

typedef struct __attribute__((packed)) {
  uint8_t type;
  uint8_t seq;
  union {
    motion_payload_t motion;
    button_payload_t button;
    uint8_t battery;
    uint8_t status;
    uint8_t raw[7];
  } u;
} bridge_packet_t;

enum {
  BUS_MOTION = 1,
  BUS_BUTTON = 2,
  BUS_BATTERY = 3,
  BUS_STATUS = 4,
};

typedef struct {
  uint8_t type;
  union {
    motion_payload_t motion;
    button_payload_t button;
    uint8_t battery;
    uint8_t status;
  } u;
} bus_event_t;

/** Minimum wire size for type (header + payload). 0 = unknown/reject. */
size_t bridge_packet_min_len(uint8_t type);

/** Validate type + length. Does not guess truncated payloads. */
bool bridge_packet_validate(const uint8_t *data, size_t len);

/** Parse LE packet into struct. Returns false if invalid. */
bool bridge_packet_parse(const uint8_t *data, size_t len, bridge_packet_t *out);

/** Encode packet to buffer. Returns bytes written or 0 on error. */
size_t bridge_packet_encode(const bridge_packet_t *pkt, uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif
