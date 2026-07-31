/**
 * MR-Proxy — kiến trúc mới
 *
 * Core0: BLE + RemoteManager (Connection Manager state machine)
 * Core1: Event Bus → Mac GATT notify
 *
 * LG Remote (Peripheral) ← Central — ESP32 — Peripheral → Mac (Custom GATT)
 * Event Bus tách Remote Driver khỏi Mac Bridge.
 */

#include <Arduino.h>
#include "config.h"
#include "event_bus.h"
#include "remote_decoder.h"
#include "remote_manager.h"
#include "mac_gatt.h"
#include "mac_bridge.h"

static RemoteDecoder gDecoder;
static RemoteManager gRemote;

void proxyOnMacCommand(const uint8_t *data, size_t len) {
  if (!data || len < 1) return;
  if (data[0] == 0x01) {
    gDecoder.reset();
    Serial.println("[DEC] calib via Mac CMD");
  }
}

static void remoteTask(void *) {
  Serial.println("[RM] task start (core0)");
  for (;;) {
    gRemote.tick();
    vTaskDelay(pdMS_TO_TICKS(20));
  }
}

void setup() {
  Serial.begin(115200);
  delay(600);
  Serial.println();
  Serial.println("========================================");
  Serial.println("MR-Proxy architecture v1");
  Serial.println("  Remote Manager + Event Bus + Mac GATT");
  Serial.println("========================================");

  if (!eventBusInit()) {
    Serial.println("FATAL event bus");
    return;
  }

  gDecoder.reset();
  macGatt().begin(kProxyName);
  gRemote.begin(&gDecoder);

  macBridgeStartTask();
  xTaskCreatePinnedToCore(remoteTask, "remoteMgr", 8192, nullptr, 5, nullptr, 0);

  Serial.println("[BOOT] Wait Mac Connect \"MR-Proxy\" then remote SCAN");
}

void loop() {
  // Heartbeat nhẹ — logic nằm trong task
  static uint32_t last = 0;
  if (millis() - last > 5000) {
    last = millis();
    Serial.printf("[HB] rm=%s mac=%d/%d\n", gRemote.stateName(),
                  (int)macGatt().macConnected(), (int)macGatt().macBonded());
  }
  delay(200);
}
