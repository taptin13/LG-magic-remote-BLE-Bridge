/**
 * MR-Proxy — ESP-IDF + NimBLE (không dùng Arduino BLEDevice)
 *
 * LG Remote ← Central — ESP32 — Peripheral → Mac (Custom GATT)
 * BleCoreTask = sole GAP/Event-notify owner; remote_manager_tick chạy trên BleCore.
 */

#include "config.h"
#include "event_bus.h"
#include "remote_decoder.h"
#include "remote_manager.h"
#include "mac_gatt.h"
#include "mac_bridge.h"
#include "ble_core.h"
#include "bridge_state.h"
#include "bridge_metrics.h"
#include "transport_channels.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <math.h>
#include <string.h>

/* Declared in NimBLE store config; no public header in some IDF versions */
void ble_store_config_init(void);

static const char *TAG = "BOOT";
static remote_decoder_t *s_dec;

static void on_mac_cmd(const uint8_t *data, uint16_t len) {
  if (!data || len < 1 || !s_dec) return;
  switch (data[0]) {
    case 0x01: /* calib bias */
      remote_decoder_reset(s_dec);
      ESP_LOGI(TAG, "CMD calib");
      break;
    case 0x02: /* sens + thresh + dead (3× float32 LE) */
      if (len >= 13) {
        float sens, thresh, dead;
        memcpy(&sens, data + 1, 4);
        memcpy(&thresh, data + 5, 4);
        memcpy(&dead, data + 9, 4);
        if (!isfinite(sens) || !isfinite(thresh) || !isfinite(dead)) {
          ESP_LOGW(TAG, "CMD sens reject non-finite");
          break;
        }
        if (sens < 0.005f) sens = 0.005f;
        if (sens > 0.5f) sens = 0.5f;
        if (thresh < 20.f) thresh = 20.f;
        if (thresh > 2000.f) thresh = 2000.f;
        if (dead < 0.f) dead = 0.f;
        if (dead > 200.f) dead = 200.f;
        remote_decoder_set_sens(s_dec, sens, thresh, dead);
        ESP_LOGI(TAG, "CMD sens=%.4f thresh=%.0f dead=%.0f", sens, thresh, dead);
      }
      break;
    default:
      ESP_LOGW(TAG, "CMD unknown 0x%02X len=%u", data[0], len);
      break;
  }
}

static void host_task(void *param) {
  (void)param;
  nimble_port_run();
  nimble_port_freertos_deinit();
}

static void on_reset(int reason) {
  ESP_LOGE(TAG, "NimBLE reset reason=%d", reason);
}

static void on_sync(void) {
  ESP_LOGI(TAG, "NimBLE synced");
  /* KHÔNG ble_store_clear() — giữ bond remote giữa các lần reboot/app reconnect. */
  ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
  ble_hs_cfg.sm_bonding = 1;
  ble_hs_cfg.sm_mitm = 0;
  ble_hs_cfg.sm_sc = 0;
  ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
  ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

  int bonds = 0;
  ble_store_util_count(BLE_STORE_OBJ_TYPE_PEER_SEC, &bonds);
  ESP_LOGI(TAG, "NVS peer bonds=%d", bonds);

  mac_gatt_start_advertise();
}

static void heartbeat_task(void *arg) {
  (void)arg;
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(5000));
    ESP_LOGI(TAG, "HB overall=%s rem=%s mac=%d/%d", bridge_state_overall_name(),
             remote_manager_state_name(), (int)mac_gatt_mac_connected(),
             (int)mac_gatt_mac_ready());
    bridge_metrics_log();
  }
}

void app_main(void) {
  ESP_LOGI(TAG, "========================================");
  ESP_LOGI(TAG, "MR-Proxy ESP-IDF + NimBLE");
  ESP_LOGI(TAG, "  BleCoreTask — dual-role owner");
  ESP_LOGI(TAG, "========================================");

  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ret = nvs_flash_init();
  }
  ESP_ERROR_CHECK(ret);

  bridge_state_init();
  bridge_metrics_init();
  transport_channels_init();

  if (!event_bus_init()) {
    ESP_LOGE(TAG, "FATAL event bus");
    return;
  }

  s_dec = remote_decoder_create();
  if (!s_dec) {
    ESP_LOGE(TAG, "FATAL decoder");
    return;
  }
  remote_decoder_reset(s_dec);

  ret = nimble_port_init();
  if (ret != ESP_OK) {
    ESP_LOGE(TAG, "nimble_port_init failed %d", ret);
    return;
  }

  ble_hs_cfg.reset_cb = on_reset;
  ble_hs_cfg.sync_cb = on_sync;
  ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

  mac_gatt_init(on_mac_cmd);
  remote_manager_init(s_dec);
  ble_store_config_init();

  nimble_port_freertos_init(host_task);

  ble_core_start();
  mac_bridge_start();
  xTaskCreate(heartbeat_task, "hb", 2048, NULL, 1, NULL);

  ESP_LOGI(TAG, "Wait Mac Connect \"%s\" then remote SCAN", PROXY_NAME);
}
