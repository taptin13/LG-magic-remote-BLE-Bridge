#include "event_bus.h"
#include "config.h"
#include <stdio.h>

static int failures;
#define EXPECT(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static bus_event_t button(uint16_t code, uint8_t down) {
  bus_event_t ev = {.type = BUS_BUTTON};
  ev.u.button.code = code;
  ev.u.button.down = down;
  return ev;
}

static void drain(void) {
  bus_event_t ev;
  while (event_bus_take(&ev, 0)) {}
}

static void test_control_precedes_motion(void) {
  drain();
  EXPECT(event_bus_publish_motion(7, 9, 0, 0));
  bus_event_t down = button(0x40, 1);
  EXPECT(event_bus_publish(&down));
  bus_event_t out;
  EXPECT(event_bus_take(&out, 0));
  EXPECT(out.type == BUS_BUTTON && out.u.button.code == 0x40);
  EXPECT(event_bus_take(&out, 0));
  EXPECT(out.type == BUS_MOTION && out.u.motion.dx == 7 && out.u.motion.dy == 9);
}

static void test_overflow_preserves_release(void) {
  drain();
  bus_event_t release1 = button(0x40, 0);
  EXPECT(event_bus_publish(&release1));
  for (int i = 1; i < EVENT_QUEUE_LEN; i++) {
    bus_event_t status = {.type = BUS_STATUS};
    status.u.status = (uint8_t)i;
    EXPECT(event_bus_publish(&status));
  }
  bus_event_t release2 = button(0x41, 0);
  EXPECT(event_bus_publish(&release2));

  int saw1 = 0, saw2 = 0;
  bus_event_t out;
  while (event_bus_take(&out, 0)) {
    if (out.type == BUS_BUTTON && !out.u.button.down && out.u.button.code == 0x40) saw1++;
    if (out.type == BUS_BUTTON && !out.u.button.down && out.u.button.code == 0x41) saw2++;
  }
  EXPECT(saw1 == 1);
  EXPECT(saw2 == 1);
}

int main(void) {
  EXPECT(event_bus_init());
  test_control_precedes_motion();
  test_overflow_preserves_release();
  if (failures) return 1;
  puts("event_bus_tests: OK");
  return 0;
}
