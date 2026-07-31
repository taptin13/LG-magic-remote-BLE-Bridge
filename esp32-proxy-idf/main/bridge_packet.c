#include "bridge_packet.h"
#include <string.h>

size_t bridge_packet_min_len(uint8_t type) {
  switch (type) {
    case PKT_MOTION:
      return 8; /* type+seq+dx+dy+buttons; wheel optional @9 */
    case PKT_BUTTON:
      return 5;
    case PKT_BATTERY:
    case PKT_STATUS:
      return 3;
    default:
      return 0;
  }
}

bool bridge_packet_validate(const uint8_t *data, size_t len) {
  if (!data || len < 2) return false;
  size_t need = bridge_packet_min_len(data[0]);
  if (need == 0) return false;
  return len >= need;
}

bool bridge_packet_parse(const uint8_t *data, size_t len, bridge_packet_t *out) {
  if (!out || !bridge_packet_validate(data, len)) return false;
  memset(out, 0, sizeof(*out));
  out->type = data[0];
  out->seq = data[1];
  switch (out->type) {
    case PKT_MOTION:
      memcpy(&out->u.motion.dx, data + 2, 2);
      memcpy(&out->u.motion.dy, data + 4, 2);
      memcpy(&out->u.motion.buttons, data + 6, 2);
      if (len >= 9) out->u.motion.wheel = (int8_t)data[8];
      break;
    case PKT_BUTTON:
      memcpy(&out->u.button.code, data + 2, 2);
      out->u.button.down = data[4];
      break;
    case PKT_BATTERY:
      out->u.battery = data[2];
      break;
    case PKT_STATUS:
      out->u.status = data[2];
      break;
    default:
      return false;
  }
  return true;
}

size_t bridge_packet_encode(const bridge_packet_t *pkt, uint8_t *out, size_t cap) {
  if (!pkt || !out) return 0;
  size_t need = bridge_packet_min_len(pkt->type);
  if (need == 0) return 0;
  if (pkt->type == PKT_MOTION && pkt->u.motion.wheel != 0) need = 9;
  if (cap < need) return 0;
  out[0] = pkt->type;
  out[1] = pkt->seq;
  switch (pkt->type) {
    case PKT_MOTION:
      memcpy(out + 2, &pkt->u.motion.dx, 2);
      memcpy(out + 4, &pkt->u.motion.dy, 2);
      memcpy(out + 6, &pkt->u.motion.buttons, 2);
      if (need >= 9) out[8] = (uint8_t)pkt->u.motion.wheel;
      break;
    case PKT_BUTTON:
      memcpy(out + 2, &pkt->u.button.code, 2);
      out[4] = pkt->u.button.down;
      break;
    case PKT_BATTERY:
      out[2] = pkt->u.battery;
      break;
    case PKT_STATUS:
      out[2] = pkt->u.status;
      break;
    default:
      return 0;
  }
  return need;
}
