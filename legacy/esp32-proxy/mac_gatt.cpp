#include "mac_gatt.h"
#include "config.h"
#include "event_bus.h"
#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLESecurity.h>
#include <string.h>

static MacGattServer gMac;
MacGattServer &macGatt() { return gMac; }

static BLECharacteristic *gEvt = nullptr;
static BLECharacteristic *gSts = nullptr;
static BLECharacteristic *gCmd = nullptr;

#if defined(CONFIG_BLUEDROID_ENABLED)
static esp_bd_addr_t gMacAddr = {0};
#endif

class MacServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { macGatt().onConnect(); }
  void onDisconnect(BLEServer *) override { macGatt().onDisconnect(); }
#if defined(CONFIG_BLUEDROID_ENABLED)
  void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    if (param) {
      memcpy(gMacAddr, param->connect.remote_bda, sizeof(gMacAddr));
      int rc = 0;
      BLESecurity::startSecurity(gMacAddr, &rc);
      Serial.printf("[MAC] connect + startSecurity rc=%d\n", rc);
    }
    macGatt().onConnect();
    (void)s;
  }
#endif
};

class MacSecurityCB : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  void onPassKeyNotify(uint32_t) override {}
  bool onConfirmPIN(uint32_t) override { return true; }
  bool onSecurityRequest() override { return true; }
  bool onAuthorizationRequest(uint16_t, uint16_t, bool) override { return true; }
#if defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t cmpl) override {
    if (cmpl.success) {
      Serial.println("[MAC] BONDED");
      macGatt().onBonded();
    }
  }
#endif
};

class CmdCB : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    uint8_t *data = c->getData();
    size_t len = c->getLength();
    if (data && len) macGatt().onCommand(data, len);
  }
};

bool MacGattServer::begin(const char *deviceName) {
  BLEDevice::init(deviceName);
  BLEDevice::setSecurityCallbacks(new MacSecurityCB());
  BLESecurity *sec = new BLESecurity();
  (void)sec;
  BLESecurity::setAuthenticationMode(true, false, true);
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new MacServerCB());

  BLEService *svc = server->createService(BLEUUID(PROXY_SVC_UUID));
  gEvt = svc->createCharacteristic(
    BLEUUID(PROXY_EVT_UUID),
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  gEvt->addDescriptor(new BLE2902());

  gSts = svc->createCharacteristic(
    BLEUUID(PROXY_STS_UUID),
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  gSts->addDescriptor(new BLE2902());

  gCmd = svc->createCharacteristic(
    BLEUUID(PROXY_CMD_UUID),
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  gCmd->setCallbacks(new CmdCB());

  uint8_t st = (uint8_t)ST_BOOT;
  gSts->setValue(&st, 1);
  svc->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(BLEUUID(PROXY_SVC_UUID));
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.printf("[MAC] ADV \"%s\" custom GATT\n", deviceName);
  setStatus(ST_WAIT_MAC);
  return true;
}

void MacGattServer::setStatus(ProxyStatus st) {
  status_ = st;
  uint8_t b = (uint8_t)st;
  if (gSts) {
    gSts->setValue(&b, 1);
    if (connected_) gSts->notify();
  }
}

bool MacGattServer::notifyEvent(const BridgePacket *pkt) {
  if (!gEvt || !connected_ || !subscribed_ || !pkt) return false;
  BridgePacket out = *pkt;
  out.seq = ++seq_;
  gEvt->setValue((uint8_t *)&out, sizeof(out));
  gEvt->notify();
  return true;
}

void MacGattServer::onConnect() {
  connected_ = true;
  bonded_ = false;
  subscribed_ = false;
  Serial.println("[MAC] CONNECT");
}

void MacGattServer::onDisconnect() {
  connected_ = false;
  bonded_ = false;
  subscribed_ = false;
  Serial.println("[MAC] DISCONNECT — ADV again");
  setStatus(ST_WAIT_MAC);
  delay(80);
  BLEDevice::startAdvertising();
}

void MacGattServer::onBonded() {
  bonded_ = true;
  // MVP: coi bonded = Mac sẵn sàng nhận event (CCCD thường enable ngay sau)
  subscribed_ = true;
  Serial.println("[MAC] ready — start remote manager");
  setStatus(ST_SCAN_REMOTE);
}

void MacGattServer::onSubscribe(bool on) {
  subscribed_ = on;
  Serial.printf("[MAC] subscribe=%d\n", (int)on);
}

void MacGattServer::onCommand(const uint8_t *data, size_t len) {
  if (len < 1) return;
  Serial.printf("[MAC] CMD 0x%02X len=%u\n", data[0], (unsigned)len);
  extern void proxyOnMacCommand(const uint8_t *data, size_t len);
  proxyOnMacCommand(data, len);
}
