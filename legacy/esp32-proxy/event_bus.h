#pragma once
#include "bridge_packet.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool eventBusInit(void);
bool eventBusPublish(const BusEvent *ev);          // từ notify / bất kỳ task
bool eventBusPublishFromISR(const BusEvent *ev, bool *woken);
bool eventBusTake(BusEvent *out, uint32_t timeoutMs);  // Mac bridge task

#ifdef __cplusplus
}
#endif
