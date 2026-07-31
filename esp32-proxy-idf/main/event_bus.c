#include "event_bus.h"
#include "config.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "esp_attr.h"
#include "esp_log.h"

static const char *TAG = "BUS";

static QueueHandle_t s_q;
static SemaphoreHandle_t s_wake;

static portMUX_TYPE s_motion_mux = portMUX_INITIALIZER_UNLOCKED;
static int32_t s_mx, s_my;
static uint16_t s_mbtn;
static bool s_mpend;

/* Wheel separate from motion — scroll does not delay/coalesce cursor. */
static portMUX_TYPE s_wheel_mux = portMUX_INITIALIZER_UNLOCKED;
static int32_t s_mwheel;
static bool s_wpend;

static uint32_t s_overflow_drops;

bool event_bus_init(void) {
  if (s_q) return true;
  s_q = xQueueCreate(EVENT_QUEUE_LEN, sizeof(bus_event_t));
  s_wake = xSemaphoreCreateBinary();
  return s_q != NULL && s_wake != NULL;
}

static void wake(void) {
  if (s_wake) xSemaphoreGive(s_wake);
}

bool event_bus_publish_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel) {
  bool any = false;
  if (dx != 0 || dy != 0) {
    portENTER_CRITICAL(&s_motion_mux);
    s_mx += dx;
    s_my += dy;
    if (s_mx > MOTION_ACCUM_MAX) s_mx = MOTION_ACCUM_MAX;
    if (s_mx < -MOTION_ACCUM_MAX) s_mx = -MOTION_ACCUM_MAX;
    if (s_my > MOTION_ACCUM_MAX) s_my = MOTION_ACCUM_MAX;
    if (s_my < -MOTION_ACCUM_MAX) s_my = -MOTION_ACCUM_MAX;
    s_mbtn = buttons;
    s_mpend = true;
    portEXIT_CRITICAL(&s_motion_mux);
    any = true;
  }
  if (wheel != 0) {
    (void)event_bus_publish_wheel(wheel);
    any = true;
  } else if (any) {
    wake();
  }
  return any || (dx == 0 && dy == 0 && wheel == 0);
}

bool event_bus_publish_wheel(int8_t wheel) {
  if (wheel == 0) return false;
  portENTER_CRITICAL(&s_wheel_mux);
  s_mwheel += wheel;
  if (s_mwheel > 127) s_mwheel = 127;
  if (s_mwheel < -127) s_mwheel = -127;
  s_wpend = true;
  portEXIT_CRITICAL(&s_wheel_mux);
  wake();
  return true;
}

void event_bus_reset_motion(void) {
  portENTER_CRITICAL(&s_motion_mux);
  s_mx = s_my = 0;
  s_mbtn = 0;
  s_mpend = false;
  portEXIT_CRITICAL(&s_motion_mux);

  portENTER_CRITICAL(&s_wheel_mux);
  s_mwheel = 0;
  s_wpend = false;
  portEXIT_CRITICAL(&s_wheel_mux);
}

bool event_bus_take_motion(motion_payload_t *out) {
  if (!out) return false;

  /* Prefer cursor; wheel taken separately on next take. */
  portENTER_CRITICAL(&s_motion_mux);
  if (s_mpend) {
    int32_t dx = s_mx, dy = s_my;
    uint16_t btn = s_mbtn;
    s_mx = s_my = 0;
    s_mpend = false;
    portEXIT_CRITICAL(&s_motion_mux);
    if (dx > 32767) dx = 32767;
    if (dx < -32768) dx = -32768;
    if (dy > 32767) dy = 32767;
    if (dy < -32768) dy = -32768;
    out->dx = (int16_t)dx;
    out->dy = (int16_t)dy;
    out->buttons = btn;
    out->wheel = 0;
    return true;
  }
  portEXIT_CRITICAL(&s_motion_mux);

  portENTER_CRITICAL(&s_wheel_mux);
  if (!s_wpend) {
    portEXIT_CRITICAL(&s_wheel_mux);
    return false;
  }
  int32_t wh = s_mwheel;
  s_mwheel = 0;
  s_wpend = false;
  portEXIT_CRITICAL(&s_wheel_mux);
  if (wh > 127) wh = 127;
  if (wh < -127) wh = -127;
  out->dx = 0;
  out->dy = 0;
  out->buttons = 0;
  out->wheel = (int8_t)wh;
  return true;
}

void event_bus_requeue_motion(int16_t dx, int16_t dy, uint16_t buttons, int8_t wheel) {
  /* Motion fail → drop dx/dy (latency). Keep wheel only on separate channel. */
  (void)dx;
  (void)dy;
  (void)buttons;
  if (wheel != 0) (void)event_bus_publish_wheel(wheel);
}

static bool queue_send_prio(const bus_event_t *ev) {
  if (xQueueSend(s_q, ev, 0) == pdTRUE) return true;

  if (ev->type != BUS_BUTTON && ev->type != BUS_STATUS) return false;

  bus_event_t discarded;
  if (xQueueReceive(s_q, &discarded, 0) != pdTRUE) return false;
  s_overflow_drops++;
  if ((s_overflow_drops % 16u) == 1u) {
    ESP_LOGW(TAG, "queue full — drop type=%u for type=%u (drops=%lu)",
             (unsigned)discarded.type, (unsigned)ev->type, (unsigned long)s_overflow_drops);
  }
  if (xQueueSend(s_q, ev, 0) != pdTRUE) return false;

  if (discarded.type == BUS_BUTTON && discarded.u.button.down == 0) {
    (void)xQueueSend(s_q, &discarded, 0);
  }
  return true;
}

bool event_bus_publish(const bus_event_t *ev) {
  if (!s_q || !ev) return false;
  if (ev->type == BUS_MOTION) {
    return event_bus_publish_motion(ev->u.motion.dx, ev->u.motion.dy, ev->u.motion.buttons,
                                    ev->u.motion.wheel);
  }
  bool ok = queue_send_prio(ev);
  if (ok) wake();
  return ok;
}

bool event_bus_take(bus_event_t *out, uint32_t timeout_ms) {
  if (!s_q || !out) return false;
  if (event_bus_take_motion(&out->u.motion)) {
    out->type = BUS_MOTION;
    return true;
  }
  TickType_t t = (timeout_ms == UINT32_MAX) ? portMAX_DELAY : pdMS_TO_TICKS(timeout_ms);
  if (xQueueReceive(s_q, out, 0) == pdTRUE) return true;
  if (timeout_ms == 0) return false;
  if (s_wake) xSemaphoreTake(s_wake, t);
  if (event_bus_take_motion(&out->u.motion)) {
    out->type = BUS_MOTION;
    return true;
  }
  return xQueueReceive(s_q, out, 0) == pdTRUE;
}
