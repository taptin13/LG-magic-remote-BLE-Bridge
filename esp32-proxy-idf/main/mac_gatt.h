#pragma once
#include "bridge_packet.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mac_cmd_cb_t)(const uint8_t *data, uint16_t len);

void mac_gatt_init(mac_cmd_cb_t cmd_cb);
void mac_gatt_start_advertise(void);
void mac_gatt_stop_advertise(void);
/** BleCoreTask only — thực thi ADV. */
void mac_gatt_adv_start_raw(void);
void mac_gatt_set_status(uint8_t st);
/** BleCoreTask only — notify status char. */
void mac_gatt_set_status_raw(uint8_t st);
/** Enqueue Event notify qua ble_core. */
bool mac_gatt_notify_event(const bridge_packet_t *pkt);
/** BleCoreTask only — ble_gatts_notify_custom Event. */
bool mac_gatt_notify_raw(const bridge_packet_t *pkt);
bool mac_gatt_mac_connected(void);
bool mac_gatt_mac_ready(void);
uint32_t mac_gatt_link_gen(void);
#ifdef __cplusplus
}
#endif
