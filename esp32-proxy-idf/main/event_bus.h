#pragma once
#include "bridge_packet.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool event_bus_init(void);
bool event_bus_publish(const bus_event_t *ev);
bool event_bus_publish_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel);
bool event_bus_publish_wheel(int8_t wheel);
bool event_bus_take_motion(motion_payload_t *out);
void event_bus_requeue_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel);
bool event_bus_take(bus_event_t *out, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif
