#include "event_bus.h"
#include <string.h>

#define STUB_Q 64

static bus_event_t s_q[STUB_Q];
static int s_n;
static int s_head;

bool event_bus_init(void) {
  s_n = s_head = 0;
  return true;
}

bool event_bus_publish(const bus_event_t *ev) {
  if (!ev || s_n >= STUB_Q) return false;
  int i = (s_head + s_n) % STUB_Q;
  s_q[i] = *ev;
  s_n++;
  return true;
}

bool event_bus_publish_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel) {
  bus_event_t ev = {.type = BUS_MOTION};
  ev.u.motion.dx = dx;
  ev.u.motion.dy = dy;
  ev.u.motion.buttons = buttons;
  ev.u.motion.wheel = wheel;
  return event_bus_publish(&ev);
}

bool event_bus_publish_wheel(int8_t wheel) {
  return event_bus_publish_motion(0, 0, 0, wheel);
}

bool event_bus_take_motion(motion_payload_t *out) {
  (void)out;
  return false;
}

void event_bus_requeue_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel) {
  (void)dx;
  (void)dy;
  (void)buttons;
  (void)wheel;
}

bool event_bus_take(bus_event_t *out, uint32_t timeout_ms) {
  (void)timeout_ms;
  if (!out || s_n == 0) return false;
  *out = s_q[s_head];
  s_head = (s_head + 1) % STUB_Q;
  s_n--;
  return true;
}

int event_bus_stub_count(void) { return s_n; }
void event_bus_stub_reset(void) { s_n = s_head = 0; }
