#include "bridge_metrics.h"
#include "esp_log.h"
#include "esp_timer.h"

static const char *TAG = "METRICS";
static bridge_metrics_t s_m;
static uint32_t s_last_motion_ok;
static uint32_t s_last_remote_fd;
static uint32_t s_last_decoder_us;
static int64_t s_last_log_us;

void bridge_metrics_init(void) {
  s_m = (bridge_metrics_t){0};
  s_last_motion_ok = 0;
  s_last_remote_fd = 0;
  s_last_decoder_us = 0;
  s_last_log_us = 0;
}

bridge_metrics_t *bridge_metrics(void) { return &s_m; }

void bridge_metrics_log(void) {
  int64_t now = esp_timer_get_time();
  uint32_t rate = 0;
  if (s_last_log_us > 0 && now > s_last_log_us) {
    uint64_t count = s_m.motion_notify_ok - s_last_motion_ok;
    rate = (uint32_t)((count * 1000000ULL) / (uint64_t)(now - s_last_log_us));
  }
  s_last_motion_ok = s_m.motion_notify_ok;
  s_last_log_us = now;

  uint32_t fd_delta = s_m.remote_fd_count - s_last_remote_fd;
  uint32_t decode_delta = s_m.decoder_total_us - s_last_decoder_us;
  uint32_t decode_avg_us = fd_delta ? decode_delta / fd_delta : 0;
  s_last_remote_fd = s_m.remote_fd_count;
  s_last_decoder_us = s_m.decoder_total_us;

  ESP_LOGI(TAG,
           "tx_drop m/b/o=%lu/%lu/%lu ovf=%lu nfy=%lu sess_mis=%lu "
           "recon=%lu syn_rel=%lu mac_disc=%lu reason=%lu rx_drop=%lu",
           (unsigned long)s_m.tx_drop_motion, (unsigned long)s_m.tx_drop_button,
           (unsigned long)s_m.tx_drop_other, (unsigned long)s_m.tx_overflow,
           (unsigned long)s_m.tx_notify_fail, (unsigned long)s_m.session_mismatch,
           (unsigned long)s_m.reconnect_count,
           (unsigned long)s_m.button_synthetic_release,
           (unsigned long)s_m.mac_disconnect_count,
           (unsigned long)s_m.mac_disconnect_reason,
           (unsigned long)s_m.remote_rx_drop);
  ESP_LOGI(TAG,
           "timeouts scan/conn/sec/disc/cccd=%lu/%lu/%lu/%lu/%lu "
           "motion coal/sat/req=%lu/%lu/%lu nfy_ok=%lu (%lu/s)",
           (unsigned long)s_m.scan_timeout, (unsigned long)s_m.connect_timeout,
           (unsigned long)s_m.security_timeout, (unsigned long)s_m.discovery_timeout,
           (unsigned long)s_m.cccd_timeout,
           (unsigned long)s_m.motion_coalesced, (unsigned long)s_m.motion_saturated,
           (unsigned long)s_m.motion_requeued, (unsigned long)s_m.motion_notify_ok,
           (unsigned long)rate);
  ESP_LOGI(TAG, "decoder fd=%lu avg/max=%lu/%lu us",
           (unsigned long)s_m.remote_fd_count, (unsigned long)decode_avg_us,
           (unsigned long)s_m.decoder_max_us);
}
