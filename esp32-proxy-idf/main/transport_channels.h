#pragma once
#include "bridge_packet.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Typed transport API — bounded relative-motion coalescing / button reliable / status latest.
 * Currently delegates to ble_core_submit_packet (TX owner).
 */

void transport_channels_init(void);

bool transport_publish_motion(const bridge_packet_t *pkt);
bool transport_publish_button(const bridge_packet_t *pkt);
bool transport_publish_status(const bridge_packet_t *pkt);
bool transport_publish_battery(const bridge_packet_t *pkt);

#ifdef __cplusplus
}
#endif
