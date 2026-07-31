#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint32_t tx_drop_motion;
  uint32_t tx_drop_button;
  uint32_t tx_drop_other;
  uint32_t tx_notify_fail;
  uint32_t tx_overflow;
  uint32_t session_mismatch;
  uint32_t scan_timeout;
  uint32_t connect_timeout;
  uint32_t security_timeout;
  uint32_t discovery_timeout;
  uint32_t cccd_timeout;
  uint32_t reconnect_count;
  uint32_t button_synthetic_release;
} bridge_metrics_t;

void bridge_metrics_init(void);
bridge_metrics_t *bridge_metrics(void);
void bridge_metrics_log(void);

#ifdef __cplusplus
}
#endif
