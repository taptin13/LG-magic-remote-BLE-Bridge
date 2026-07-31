#include "ble_tx.h"
#include "ble_core.h"

void ble_tx_init(void) { ble_core_init(); }

void ble_tx_start(void) {
  /* BleCoreTask owns TX — started via ble_core_start(). */
}

bool ble_tx_submit(const bridge_packet_t *pkt) { return ble_core_submit_packet(pkt); }

void ble_tx_flush(void) { ble_core_flush_tx(); }

uint32_t ble_tx_generation(void) { return ble_core_tx_gen(); }
