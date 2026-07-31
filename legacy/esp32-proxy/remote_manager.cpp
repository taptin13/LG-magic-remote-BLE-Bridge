#include "remote_manager.h"
#include "config.h"
#include "mac_gatt.h"
#include "bridge_packet.h"
#include <Arduino.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include <BLEClient.h>
#include <BLESecurity.h>
#include <string.h>

static RemoteManager *gRM = nullptr;
static BLEAddress *gTarget = nullptr;
static BLEClient *gClient = nullptr;
static Preferences gPrefs;

static volatile bool gGotTarget = false;
static volatile bool gScanDoneFlag = false;
static volatile bool gRemoteDrop = false;
static uint8_t gPendingAddrType = 0;

static BLEUUID kSvcD1FF(REMOTE_SVC_D1FF);
static BLEUUID kSvcHID((uint16_t)0x1812);
static BLEUUID kCharA001((uint16_t)0xA001);
static BLEUUID kChar2A4D((uint16_t)0x2A4D);
static BLEUUID kChar2A4E((uint16_t)0x2A4E);
static BLEUUID kDesc2908((uint16_t)0x2908);

static uint16_t gRepHandles[16];
static uint8_t gRepIds[16];
static int gRepCount = 0;

static void rememberReport(uint16_t handle, uint8_t id) {
  if (gRepCount >= 16) return;
  gRepHandles[gRepCount] = handle;
  gRepIds[gRepCount] = id;
  gRepCount++;
}

static uint8_t reportIdForHandle(uint16_t h) {
  for (int i = 0; i < gRepCount; i++)
    if (gRepHandles[i] == h) return gRepIds[i];
  return 0;
}

static void smpForRemote() {
  BLESecurity::resetSecurity();
  BLESecurity::setAuthenticationMode(true, false, false);  // Legacy JW
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);
}

static void notifyCB(BLERemoteCharacteristic *c, uint8_t *data, size_t len, bool) {
  if (!gRM || !data || len == 0) return;
  uint8_t rid = reportIdForHandle(c->getHandle());
  // Forward vào decoder qua public hook
  extern void remoteManagerOnNotify(uint8_t rid, uint8_t *data, size_t len);
  remoteManagerOnNotify(rid, data, len);
}

class RMClientCB : public BLEClientCallbacks {
  void onConnect(BLEClient *) override { Serial.println("[RM] REMOTE CONNECT"); }
  void onDisconnect(BLEClient *) override {
    Serial.println("[RM] REMOTE DISCONNECT");
    gRemoteDrop = true;
  }
};

class RMScanCB : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice d) override {
    if (!gRM) return;
    if (gRM->state() != RemoteManager::Scanning && gRM->state() != RemoteManager::ReconnectWait) return;
    if (!d.haveName() || d.getName() != kRemoteName) return;
    Serial.printf("[RM] found %s rssi=%d\n", d.getName().c_str(), d.getRSSI());
    BLEDevice::getScan()->stop();
    if (gTarget) delete gTarget;
    gTarget = new BLEAddress(d.getAddress());
    extern void remoteManagerGotTarget(uint8_t addrType);
    remoteManagerGotTarget(d.getAddressType());
  }
};
static RMScanCB gScanCB;

static void onScanDone(BLEScanResults) {
  extern void remoteManagerScanDone();
  remoteManagerScanDone();
}

void remoteManagerGotTarget(uint8_t addrType) {
  gPendingAddrType = addrType;
  gGotTarget = true;
}
void remoteManagerScanDone() { gScanDoneFlag = true; }
void remoteManagerOnNotify(uint8_t rid, uint8_t *data, size_t len) {
  if (gRM) gRM->onNotify(rid, data, len);
}

void RemoteManager::onNotify(uint8_t reportId, uint8_t *data, size_t len) {
  if (reportId == 0xFD && decoder_ && len >= 19) decoder_->onFD(data, len);
}

const char *RemoteManager::stateName() const {
  switch (state_) {
    case Idle: return "Idle";
    case WaitMac: return "WaitMac";
    case Scanning: return "Scanning";
    case Connecting: return "Connecting";
    case Discover: return "Discover";
    case Secure: return "Secure";
    case Ready: return "Ready";
    case ReconnectWait: return "ReconnectWait";
    default: return "?";
  }
}

void RemoteManager::setState(State s) {
  if (state_ == s) return;
  state_ = s;
  stateMs_ = millis();
  Serial.printf("[RM] state → %s\n", stateName());
}

void RemoteManager::begin(RemoteDecoder *decoder) {
  gRM = this;
  decoder_ = decoder;
  loadCache();
  setState(WaitMac);
}

void RemoteManager::loadCache() {
  gPrefs.begin("mrproxy", true);
  paired_ = gPrefs.getBool("paired", false);
  gPrefs.end();
  Serial.printf("[RM] cache paired=%d\n", (int)paired_);
}

void RemoteManager::saveCache() {
  gPrefs.begin("mrproxy", false);
  gPrefs.putBool("paired", true);
  gPrefs.end();
  paired_ = true;
  Serial.println("[RM] cache paired=1");
}

void RemoteManager::startScanBurst() {
  BLEDevice::getScan()->stop();
  delay(20);
  smpForRemote();
  BLEScan *scan = BLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(&gScanCB, true);
  scan->setInterval(160);
  scan->setWindow(48);
  scan->setActiveScan(true);
  scanStartedMs_ = millis();
  gGotTarget = false;
  gScanDoneFlag = false;
  Serial.printf("[RM] SCAN burst %ds \"%s\"%s\n", SCAN_BURST_SEC, kRemoteName,
                paired_ ? " (reconnect — bấm nút remote)" : "");
  // Non-blocking async scan
  if (!scan->start(SCAN_BURST_SEC, onScanDone, false)) {
    Serial.println("[RM] SCAN start fail");
    gScanDoneFlag = true;
  }
  setState(Scanning);
  macGatt().setStatus(ST_SCAN_REMOTE);
}

void RemoteManager::tryConnect() {
  if (!gTarget) {
    setState(ReconnectWait);
    return;
  }
  setState(Connecting);
  macGatt().setStatus(ST_REMOTE_CONN);

  if (gClient) {
    if (gClient->isConnected()) gClient->disconnect();
    delay(100);
    delete gClient;
    gClient = nullptr;
  }
  smpForRemote();
  delay(40);
  gClient = BLEDevice::createClient();
  gClient->setClientCallbacks(new RMClientCB());
  Serial.printf("[RM] connecting…\n");
  if (!gClient->connect(*gTarget, gPendingAddrType)) {
    Serial.println("[RM] connect FAIL");
    setState(ReconnectWait);
    return;
  }
  setState(Secure);
  bool ok = gClient->secureConnection();
  Serial.printf("[RM] secure → %s\n", ok ? "ok" : "FAIL");
  if (!ok) {
    gClient->disconnect();
    setState(ReconnectWait);
    return;
  }
  setState(Discover);
  if (!discoverAndSubscribe()) {
    setState(ReconnectWait);
    return;
  }
  saveCache();
  if (decoder_) decoder_->reset();
  setState(Ready);
  macGatt().setStatus(ST_READY);
  Serial.println("[RM] READY");
}

bool RemoteManager::discoverAndSubscribe() {
  gRepCount = 0;
  if (!gClient) return false;
  gClient->updateConnParams(12, 24, 0, 400);
  delay(150);

  if (BLERemoteService *d1 = gClient->getService(kSvcD1FF)) {
    if (BLERemoteCharacteristic *a001 = d1->getCharacteristic(kCharA001)) {
      if (a001->canNotify()) {
        a001->registerForNotify(notifyCB);
        Serial.println("[RM] notify A001");
      }
    }
  }
  if (BLERemoteService *hid = gClient->getService(kSvcHID)) {
    if (BLERemoteCharacteristic *proto = hid->getCharacteristic(kChar2A4E)) {
      uint8_t mode = 0x01;
      if (proto->canWrite() || proto->canWriteNoResponse())
        proto->writeValue(&mode, 1, !proto->canWriteNoResponse());
    }
    auto *byHandle = hid->getCharacteristicsByHandle();
    if (byHandle) {
      for (auto &kv : *byHandle) {
        BLERemoteCharacteristic *c = kv.second;
        if (!c->getUUID().equals(kChar2A4D)) continue;
        if (auto *descs = c->getDescriptors()) {
          for (auto &dk : *descs) {
            BLERemoteDescriptor *d = dk.second;
            if (d->getUUID().equals(kDesc2908)) {
              String v = d->readValue();
              if (v.length() >= 1) rememberReport(c->getHandle(), (uint8_t)v[0]);
            }
          }
        }
        if (c->canNotify() || c->canIndicate()) c->registerForNotify(notifyCB);
      }
    }
    Serial.printf("[RM] HID reports cached=%d\n", gRepCount);
  }
  return true;
}

void RemoteManager::tick() {
  // Mac chưa sẵn sàng
  if (state_ == WaitMac) {
    if (macGatt().macBonded() && macGatt().macSubscribed()) {
      BLEDevice::getAdvertising()->stop();
      startScanBurst();
    }
    return;
  }

  if (gGotTarget) {
    gGotTarget = false;
    haveTarget_ = true;
    doConnect_ = true;
  }

  if (state_ == Scanning) {
    if (doConnect_) {
      doConnect_ = false;
      tryConnect();
      return;
    }
    if (gScanDoneFlag || (millis() - scanStartedMs_ > (SCAN_BURST_SEC + 2) * 1000UL)) {
      gScanDoneFlag = false;
      setState(ReconnectWait);
    }
    return;
  }

  if (state_ == ReconnectWait) {
    if (millis() - stateMs_ > 400) startScanBurst();
    return;
  }

  if (state_ == Ready) {
    if (gRemoteDrop || (gClient && !gClient->isConnected())) {
      gRemoteDrop = false;
      Serial.println("[RM] link lost");
      macGatt().setStatus(ST_REMOTE_DROP);
      setState(ReconnectWait);
    }
  }
}
