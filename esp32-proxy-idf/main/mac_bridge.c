#include "mac_bridge.h"
#include "event_bus.h"
#include "mac_gatt.h"
#include "bridge_packet.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "BRIDGE";

/**
 * Producer only — does not call NimBLE directly.
 * BleCoreTask drain Event notify.
 */
static void mac_bridge_task(void *arg) {
  (void)arg;
  ESP_LOGI(TAG, "task start (event_bus → ble_core)");
  for (;;) {
    bus_event_t ev;
    if (!event_bus_take(&ev, 20)) continue;

    bridge_packet_t pkt = {0};
    switch (ev.type) {
      case BUS_MOTION:
        pkt.type = PKT_MOTION;
        pkt.u.motion = ev.u.motion;
        (void)mac_gatt_notify_event(&pkt);
        break;
      case BUS_BUTTON:
        pkt.type = PKT_BUTTON;
        pkt.u.button = ev.u.button;
        (void)mac_gatt_notify_event(&pkt);
        break;
      case BUS_BATTERY:
        pkt.type = PKT_BATTERY;
        pkt.u.battery = ev.u.battery;
        (void)mac_gatt_notify_event(&pkt);
        break;
      case BUS_STATUS:
        pkt.type = PKT_STATUS;
        pkt.u.status = ev.u.status;
        (void)mac_gatt_notify_event(&pkt);
        break;
      default:
        break;
    }
  }
}

void mac_bridge_start(void) {
  xTaskCreatePinnedToCore(mac_bridge_task, "macBridge", 3072, NULL, 8, NULL, 1);
}
