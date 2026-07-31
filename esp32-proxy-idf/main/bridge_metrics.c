#include "bridge_metrics.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "METRICS";
static bridge_metrics_t s_m;
static uint32_t s_last_motion_ok;
static int64_t s_last_log_us;

void bridge_metrics_init(void) {
  s_m = (bridge_metrics_t){0};
  s_last_motion_ok = 0;
  s_last_log_us = 0;
}

bridge_metrics_t *bridge_metrics(void) { return &s_m; }

void bridge_metrics_log(void) {
  int64_t now = esp_timer_get_time();
  double rate = 0.0;
  if (s_last_log_us > 0 && now > s_last_log_us) {
    rate = (double)(s_m.motion_notify_ok - s_last_motion_ok) * 1e6 /
           (double)(now - s_last_log_us);
  }
  s_last_motion_ok = s_m.motion_notify_ok;
  s_last_log_us = now;

  ESP_LOGI(TAG,
           "tx_drop m/b/o=%lu/%lu/%lu ovf=%lu nfy=%lu sess_mis=%lu "
           "to scan/conn/sec/disc/cccd=%lu/%lu/%lu/%lu/%lu recon=%lu syn_rel=%lu "
           "motion coal/sat/req=%lu/%lu/%lu nfy_ok=%lu (%.1f/s)",
           (unsigned long)s_m.tx_drop_motion, (unsigned long)s_m.tx_drop_button,
           (unsigned long)s_m.tx_drop_other, (unsigned long)s_m.tx_overflow,
           (unsigned long)s_m.tx_notify_fail, (unsigned long)s_m.session_mismatch,
           (unsigned long)s_m.scan_timeout, (unsigned long)s_m.connect_timeout,
           (unsigned long)s_m.security_timeout, (unsigned long)s_m.discovery_timeout,
           (unsigned long)s_m.cccd_timeout, (unsigned long)s_m.reconnect_count,
           (unsigned long)s_m.button_synthetic_release,
           (unsigned long)s_m.motion_coalesced, (unsigned long)s_m.motion_saturated,
           (unsigned long)s_m.motion_requeued, (unsigned long)s_m.motion_notify_ok, rate);
}
