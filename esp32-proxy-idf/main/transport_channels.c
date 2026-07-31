#include "transport_channels.h"
#include "ble_core.h"

void transport_channels_init(void) {
  ble_core_init();
}

bool transport_publish_motion(const bridge_packet_t *pkt) {
  if (!pkt || pkt->type != PKT_MOTION) return false;
  return ble_core_submit_packet(pkt);
}

bool transport_publish_button(const bridge_packet_t *pkt) {
  if (!pkt || pkt->type != PKT_BUTTON) return false;
  return ble_core_submit_packet(pkt);
}

bool transport_publish_status(const bridge_packet_t *pkt) {
  if (!pkt || pkt->type != PKT_STATUS) return false;
  return ble_core_submit_packet(pkt);
}

bool transport_publish_battery(const bridge_packet_t *pkt) {
  if (!pkt || pkt->type != PKT_BATTERY) return false;
  return ble_core_submit_packet(pkt);
}
