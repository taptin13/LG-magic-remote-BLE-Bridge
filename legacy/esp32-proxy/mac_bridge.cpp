#include "mac_bridge.h"
#include "event_bus.h"
#include "mac_gatt.h"
#include "bridge_packet.h"
#include <Arduino.h>

static void macBridgeTask(void *) {
  Serial.println("[BRIDGE] task start (core1)");
  for (;;) {
    BusEvent ev;
    if (!eventBusTake(&ev, 50)) continue;

    BridgePacket pkt{};
    switch (ev.type) {
      case BUS_MOTION:
        pkt.type = PKT_MOTION;
        pkt.u.motion = ev.u.motion;
        macGatt().notifyEvent(&pkt);
        break;
      case BUS_BUTTON:
        pkt.type = PKT_BUTTON;
        pkt.u.button = ev.u.button;
        macGatt().notifyEvent(&pkt);
        break;
      case BUS_BATTERY:
        pkt.type = PKT_BATTERY;
        pkt.u.battery = ev.u.battery;
        macGatt().notifyEvent(&pkt);
        break;
      case BUS_STATUS:
        pkt.type = PKT_STATUS;
        pkt.u.status = ev.u.status;
        macGatt().notifyEvent(&pkt);
        break;
      default:
        break;
    }
  }
}

void macBridgeStartTask(void) {
  xTaskCreatePinnedToCore(macBridgeTask, "macBridge", 4096, nullptr, 4, nullptr, 1);
}
