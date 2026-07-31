#pragma once
#include <stdint.h>

// Binary wire format Mac ↔ ESP32 (không JSON)
enum BridgePktType : uint8_t {
  PKT_MOTION  = 1,
  PKT_BUTTON  = 2,
  PKT_BATTERY = 3,
  PKT_STATUS  = 4,
  PKT_VOICE   = 5,  // reserved
};

enum ProxyStatus : uint8_t {
  ST_BOOT = 0,
  ST_WAIT_MAC = 1,
  ST_SCAN_REMOTE = 2,
  ST_REMOTE_CONN = 3,
  ST_READY = 4,
  ST_REMOTE_DROP = 5,
};

#pragma pack(push, 1)
struct MotionPayload {
  int16_t dx;
  int16_t dy;
  uint16_t buttons;  // bit0=L bit1=R
};

struct ButtonPayload {
  uint16_t code;
  uint8_t down;  // 1=press 0=release
};

struct BatteryPayload {
  uint8_t percent;
};

struct BridgePacket {
  uint8_t type;
  uint8_t seq;
  union {
    MotionPayload motion;
    ButtonPayload button;
    BatteryPayload battery;
    uint8_t status;
    uint8_t raw[6];
  } u;
};
#pragma pack(pop)

static_assert(sizeof(BridgePacket) <= 20, "keep under default ATT MTU payload");

// Internal bus event (ESP32 FreeRTOS queue)
enum BusEventType : uint8_t {
  BUS_MOTION = 1,
  BUS_BUTTON = 2,
  BUS_BATTERY = 3,
  BUS_STATUS = 4,
  BUS_RAW_FD = 5,
};

struct BusEvent {
  BusEventType type;
  union {
    MotionPayload motion;
    ButtonPayload button;
    BatteryPayload battery;
    uint8_t status;
    struct {
      uint8_t len;
      uint8_t data[20];
    } raw;
  } u;
};
