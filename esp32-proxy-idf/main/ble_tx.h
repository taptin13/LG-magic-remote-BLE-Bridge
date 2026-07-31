#pragma once
#include "bridge_packet.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Compatibility wrappers → ble_core (BleCoreTask owns TX). */

void ble_tx_init(void);
void ble_tx_start(void);
bool ble_tx_submit(const bridge_packet_t *pkt);
void ble_tx_flush(void);
uint32_t ble_tx_generation(void);

#ifdef __cplusplus
}
#endif
