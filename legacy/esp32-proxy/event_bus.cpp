#include "event_bus.h"
#include "config.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

static QueueHandle_t sQueue = nullptr;

bool eventBusInit(void) {
  if (sQueue) return true;
  sQueue = xQueueCreate(EVENT_QUEUE_LEN, sizeof(BusEvent));
  return sQueue != nullptr;
}

bool eventBusPublish(const BusEvent *ev) {
  if (!sQueue || !ev) return false;
  return xQueueSend(sQueue, ev, 0) == pdTRUE;
}

bool eventBusPublishFromISR(const BusEvent *ev, bool *woken) {
  if (!sQueue || !ev) return false;
  BaseType_t w = pdFALSE;
  bool ok = xQueueSendFromISR(sQueue, ev, &w) == pdTRUE;
  if (woken) *woken = (w == pdTRUE);
  return ok;
}

bool eventBusTake(BusEvent *out, uint32_t timeoutMs) {
  if (!sQueue || !out) return false;
  TickType_t t = timeoutMs == UINT32_MAX ? portMAX_DELAY : pdMS_TO_TICKS(timeoutMs);
  return xQueueReceive(sQueue, out, t) == pdTRUE;
}
