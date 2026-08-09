/**
 * MR-Proxy — ESP-IDF + NimBLE (no Arduino BLEDevice)
 *
 * LG Remote ← Central — ESP32 — Peripheral → Mac (Custom GATT)
 * BleCoreTask = sole GAP/Event-notify owner; remote_manager_tick runs on BleCore.
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
#include "esp_heap_caps.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_store.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include <math.h>
#include <string.h>

/* Declared in NimBLE store config; no public header in some IDF versions */
void ble_store_config_init(void);

static const char *TAG = "BOOT";
static remote_decoder_t *s_dec;

#define MAC_BOND_RESET_GPIO GPIO_NUM_0 /* ESP32 DevKit BOOT button; press after boot. */
#define MAC_BOND_RESET_HOLD_MS 3000

static void mac_bond_reset_button_task(void *arg) {
  (void)arg;
  bool fired = false;
  uint32_t held_ms = 0;
  for (;;) {
    if (gpio_get_level(MAC_BOND_RESET_GPIO) == 0) {
      if (held_ms < MAC_BOND_RESET_HOLD_MS) held_ms += 50;
      if (!fired && held_ms >= MAC_BOND_RESET_HOLD_MS) {
        fired = true;
        ESP_LOGW(TAG, "BOOT held 3s — resetting Mac pairing only (remote bond kept)");
        ble_core_cmd_reset_mac_bond();
      }
    } else {
      held_ms = 0;
      fired = false;
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

static void on_mac_cmd(const uint8_t *data, uint16_t len) {
  if (!data || len < 1 || !s_dec) return;
  switch (data[0]) {
    case 0x01: /* calib bias */
      remote_decoder_reset(s_dec);
      ESP_LOGI(TAG, "CMD calib");
      break;
    case 0x02: /* sens + thresh + dead [+ tremor] (3–4× float32 LE) */
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
        float tremor = -1.f;
        if (len >= 17) {
          memcpy(&tremor, data + 13, 4);
          if (!isfinite(tremor)) {
            ESP_LOGW(TAG, "CMD tremor reject non-finite");
            tremor = -1.f;
          } else {
            if (tremor < 0.f) tremor = 0.f;
            if (tremor > 1.f) tremor = 1.f;
            remote_decoder_set_tremor(s_dec, tremor);
          }
        }
        if (tremor >= 0.f) {
          ESP_LOGI(TAG, "CMD sens=%.4f thresh=%.0f dead=%.0f tremor=%.2f", sens, thresh, dead,
                   tremor);
        } else {
          ESP_LOGI(TAG, "CMD sens=%.4f thresh=%.0f dead=%.0f", sens, thresh, dead);
        }
      }
      break;
    case 0x03: /* Mac link keepalive ping — no payload */
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
  /* Do NOT ble_store_clear() — keep remote bond across reboot/app reconnect. */
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
  unsigned n = 0;
  for (;;) {
    /* <15s: macOS Sequoia often drops idle BLE links with CBError 6
     * ("timed out unexpectedly") when there is no ATT traffic. */
    vTaskDelay(pdMS_TO_TICKS(2000));
    n++;
    if ((n % 3u) == 0u && mac_gatt_mac_ready()) {
      /* Re-notify current status — keeps the Mac↔ESP ATT path alive while the
       * remote is quiet (no motion/button notifies). Six seconds is frequent
       * enough without competing with dual-role motion traffic every 2s. */
      mac_gatt_set_status(mac_gatt_current_status());
    }
    if ((n % 5u) == 0u) {
      ESP_LOGI(TAG, "HB overall=%s rem=%s mac=%d/%d stack_free=%uW heap_free=%lu heap_min=%lu",
               bridge_state_overall_name(), remote_manager_state_name(),
               (int)mac_gatt_mac_connected(), (int)mac_gatt_mac_ready(),
               (unsigned)uxTaskGetStackHighWaterMark(NULL),
               (unsigned long)esp_get_free_heap_size(),
               (unsigned long)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT));
      bridge_metrics_log();
    }
  }
}

void app_main(void) {
  /* Per-notify NimBLE INFO logs can exceed the motion rate and waste CPU/UART
   * bandwidth. Keep our bridge INFO logs, but only emit NimBLE warnings. */
  esp_log_level_set("NimBLE", ESP_LOG_WARN);
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
  gpio_config_t reset_gpio = {
      .pin_bit_mask = 1ULL << MAC_BOND_RESET_GPIO,
      .mode = GPIO_MODE_INPUT,
      .pull_up_en = GPIO_PULLUP_ENABLE,
      .pull_down_en = GPIO_PULLDOWN_DISABLE,
      .intr_type = GPIO_INTR_DISABLE,
  };
  ESP_ERROR_CHECK(gpio_config(&reset_gpio));
  xTaskCreate(mac_bond_reset_button_task, "macBondReset", 2048, NULL, 2, NULL);
  /* ESP_LOG formatting plus metrics previously overflowed the 2KB task stack,
   * rebooting the bridge every heartbeat interval. Keep measured headroom. */
  xTaskCreate(heartbeat_task, "hb", 4096, NULL, 1, NULL);

  ESP_LOGI(TAG, "Wait Mac Connect \"%s\" then remote SCAN", PROXY_NAME);
}
