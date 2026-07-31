#pragma once
#include "bridge_packet.h"
#include <stddef.h>
#include <stdint.h>

class MacGattServer {
 public:
  bool begin(const char *deviceName);
  void setStatus(ProxyStatus st);
  bool notifyEvent(const BridgePacket *pkt);
  bool macSubscribed() const { return subscribed_; }
  bool macConnected() const { return connected_; }
  bool macBonded() const { return bonded_; }

  // gọi từ callbacks
  void onConnect();
  void onDisconnect();
  void onBonded();
  void onSubscribe(bool on);
  void onCommand(const uint8_t *data, size_t len);

 private:
  bool connected_ = false;
  bool bonded_ = false;
  bool subscribed_ = false;
  uint8_t seq_ = 0;
  ProxyStatus status_ = ST_BOOT;
};

MacGattServer &macGatt();
