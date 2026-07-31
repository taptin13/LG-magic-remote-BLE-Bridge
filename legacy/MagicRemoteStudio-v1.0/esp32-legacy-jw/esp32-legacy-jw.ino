/**
 * MR25GA — ESP32 central, Legacy Just Works
 *
 * Targets ESP32 Arduino core 3.3.x BLE API (NimBLE-backed BLEDevice wrapper).
 * Serial: 115200
 *
 * Success:
 *   [SMP] auth complete …
 *   [GAP] link still up at Xs   (X > 5)
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include <BLEClient.h>
#include <BLESecurity.h>

static const char *kTargetName = "LGE MR25GA";
static BLEUUID kSvcD1FF("0000D1FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcD0FF("0000D0FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcHID((uint16_t)0x1812);
static BLEUUID kCharA001((uint16_t)0xA001);
static BLEUUID kCharFFF1((uint16_t)0xFFF1);
static BLEUUID kChar2A4A((uint16_t)0x2A4A);
static BLEUUID kChar2A4B((uint16_t)0x2A4B);
static BLEUUID kChar2A4D((uint16_t)0x2A4D);
static BLEUUID kChar2A4E((uint16_t)0x2A4E);  // Protocol Mode
static BLEUUID kDesc2908((uint16_t)0x2908);  // Report Reference

static BLEAddress *gTargetAddr = nullptr;
static uint8_t gTargetAddrType = 0;
static bool gHaveTarget = false;
static bool gDoConnect = false;
static bool gRescan = false;
static bool gConnected = false;
static uint32_t gLinkUpMs = 0;
static uint32_t gLastAliveLogMs = 0;
static BLEClient *gClient = nullptr;

// Report ID per characteristic handle (UUID map collapses duplicates).
static const int kMaxReports = 16;
static uint16_t gRepHandles[kMaxReports];
static uint8_t gRepIds[kMaxReports];
static int gRepCount = 0;

static void rememberReport(uint16_t handle, uint8_t reportId) {
  for (int i = 0; i < gRepCount; i++) {
    if (gRepHandles[i] == handle) {
      gRepIds[i] = reportId;
      return;
    }
  }
  if (gRepCount >= kMaxReports) return;
  gRepHandles[gRepCount] = handle;
  gRepIds[gRepCount] = reportId;
  gRepCount++;
}

static uint8_t reportIdForHandle(uint16_t handle) {
  for (int i = 0; i < gRepCount; i++) {
    if (gRepHandles[i] == handle) return gRepIds[i];
  }
  return 0;
}

static void hexDump(const char *tag, const uint8_t *data, size_t len) {
  Serial.printf("%s len=%u [", tag, (unsigned)len);
  for (size_t i = 0; i < len; i++) {
    Serial.printf("%02X%s", data[i], i + 1 < len ? " " : "");
  }
  Serial.println("]");
}

static void hexDumpString(const char *tag, const String &v) {
  hexDump(tag, (const uint8_t *)v.c_str(), v.length());
}

/// Queue HID from BLE notify task; only loop() prints Serial (avoids BRIDGE UP/HID interleave).
struct HidFrame {
  uint8_t reportId;
  uint16_t handle;
  uint8_t len;
  uint8_t data[32];
};
static const int kHidQ = 96;
static HidFrame gHidQ[kHidQ];
static volatile int gHidHead = 0;
static volatile int gHidTail = 0;
static portMUX_TYPE gHidMux = portMUX_INITIALIZER_UNLOCKED;

static void enqueueHID(uint8_t reportId, uint16_t handle, const uint8_t *data, size_t len) {
  if (len > 32) len = 32;
  portENTER_CRITICAL(&gHidMux);
  int next = (gHidHead + 1) % kHidQ;
  if (next != gHidTail) {
    HidFrame &f = gHidQ[gHidHead];
    f.reportId = reportId;
    f.handle = handle;
    f.len = (uint8_t)len;
    memcpy(f.data, data, len);
    gHidHead = next;
  }
  portEXIT_CRITICAL(&gHidMux);
}

static void drainHIDQueue() {
  for (;;) {
    HidFrame f;
    portENTER_CRITICAL(&gHidMux);
    if (gHidTail == gHidHead) {
      portEXIT_CRITICAL(&gHidMux);
      break;
    }
    f = gHidQ[gHidTail];
    gHidTail = (gHidTail + 1) % kHidQ;
    portEXIT_CRITICAL(&gHidMux);

    Serial.printf("BRIDGE HID %02X %04X ", f.reportId, f.handle);
    for (uint8_t i = 0; i < f.len; i++) Serial.printf("%02X", f.data[i]);
    Serial.println();
  }
}

static void notifyCB(BLERemoteCharacteristic *c, uint8_t *data, size_t len, bool isNotify) {
  (void)isNotify;
  uint16_t handle = c->getHandle();
  uint8_t rid = reportIdForHandle(handle);
  enqueueHID(rid, handle, data, len);
}

class SecurityCB : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override {
    Serial.println("[SMP] onPassKeyRequest -> 0 (Just Works)");
    return 0;
  }
  void onPassKeyNotify(uint32_t pass_key) override {
    Serial.printf("[SMP] onPassKeyNotify %u\n", pass_key);
  }
  bool onConfirmPIN(uint32_t pass_key) override {
    Serial.printf("[SMP] onConfirmPIN %u -> accept\n", pass_key);
    return true;
  }
  bool onSecurityRequest() override {
    Serial.println("[SMP] onSecurityRequest -> accept");
    return true;
  }
  bool onAuthorizationRequest(uint16_t connHandle, uint16_t attrHandle, bool isRead) override {
    (void)connHandle;
    (void)attrHandle;
    (void)isRead;
    return true;
  }

#if defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t cmpl) override {
    Serial.printf(
      "[SMP] auth complete success=%d fail_reason=0x%x\n",
      cmpl.success,
      cmpl.fail_reason
    );
  }
#endif

#if defined(CONFIG_NIMBLE_ENABLED)
  void onAuthenticationComplete(ble_gap_conn_desc *desc) override {
    if (!desc) {
      Serial.println("[SMP] auth complete (null desc)");
      return;
    }
    Serial.printf(
      "[SMP] auth complete encrypted=%d authenticated=%d bonded=%d\n",
      desc->sec_state.encrypted,
      desc->sec_state.authenticated,
      desc->sec_state.bonded
    );
  }
#endif
};

class ClientCB : public BLEClientCallbacks {
  void onConnect(BLEClient *c) override {
    (void)c;
    gConnected = true;
    gLinkUpMs = millis();
    gLastAliveLogMs = gLinkUpMs;
    Serial.println("[GAP] connected");
    Serial.println("BRIDGE STATUS connected");
  }
  void onDisconnect(BLEClient *c) override {
    (void)c;
    float lived = gLinkUpMs ? (millis() - gLinkUpMs) / 1000.0f : 0;
    Serial.printf("[GAP] disconnected — link lived %.2fs\n", lived);
    if (lived > 0 && lived < 3.0f) {
      Serial.println("[GAP] DIED inside ~2.3s window (same as Mac/nRF unbonded)");
    } else if (lived >= 5.0f) {
      Serial.println("[GAP] SURVIVED past watchdog — bond/encrypt likely mattered");
    }
    Serial.println("BRIDGE STATUS disconnected");
    gConnected = false;
    gLinkUpMs = 0;
    gRescan = true;
  }
};

class ScanCB : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice advertisedDevice) override {
    if (!advertisedDevice.haveName()) return;
    if (advertisedDevice.getName() != kTargetName) return;

    Serial.printf(
      "[SCAN] found %s addr=%s type=%u rssi=%d\n",
      advertisedDevice.getName().c_str(),
      advertisedDevice.getAddress().toString().c_str(),
      (unsigned)advertisedDevice.getAddressType(),
      advertisedDevice.getRSSI()
    );

    BLEDevice::getScan()->stop();
    if (gTargetAddr) delete gTargetAddr;
    gTargetAddr = new BLEAddress(advertisedDevice.getAddress());
    gTargetAddrType = advertisedDevice.getAddressType();
    gHaveTarget = true;
    gDoConnect = true;
  }
};

static bool tryNotify(BLERemoteCharacteristic *c, const char *label) {
  if (!c) return false;
  if (!c->canNotify() && !c->canIndicate()) return false;
  c->registerForNotify(notifyCB);
  Serial.printf(
    "[GATT] notify %s uuid=%s handle=0x%04X\n",
    label,
    c->getUUID().toString().c_str(),
    c->getHandle()
  );
  return true;
}

static void dumpServiceByHandle(BLERemoteService *svc) {
  Serial.printf("[GATT] service %s\n", svc->getUUID().toString().c_str());
  // UUID-keyed map collapses duplicate 2A4D Reports — use handles.
  std::map<uint16_t, BLERemoteCharacteristic *> *byHandle = svc->getCharacteristicsByHandle();
  if (!byHandle) return;
  for (auto &kv : *byHandle) {
    BLERemoteCharacteristic *c = kv.second;
    String props;
    if (c->canRead()) props += "R ";
    if (c->canWrite()) props += "W ";
    if (c->canWriteNoResponse()) props += "WNR ";
    if (c->canNotify()) props += "N ";
    if (c->canIndicate()) props += "I ";
    Serial.printf(
      "  h=0x%04X char %s [%s]\n",
      c->getHandle(),
      c->getUUID().toString().c_str(),
      props.c_str()
    );
  }
}

static void setupHID(BLERemoteService *hid) {
  if (BLERemoteCharacteristic *info = hid->getCharacteristic(kChar2A4A)) {
    if (info->canRead()) hexDumpString("[GATT] HID Information", info->readValue());
  }
  if (BLERemoteCharacteristic *rmap = hid->getCharacteristic(kChar2A4B)) {
    if (rmap->canRead()) hexDumpString("[GATT] Report Map", rmap->readValue());
  }

  // Report Protocol Mode = 0x01 (not Boot Mode 0x00)
  if (BLERemoteCharacteristic *proto = hid->getCharacteristic(kChar2A4E)) {
    if (proto->canRead()) hexDumpString("[GATT] Protocol Mode before", proto->readValue());
    uint8_t reportMode = 0x01;
    if (proto->canWrite() || proto->canWriteNoResponse()) {
      proto->writeValue(&reportMode, 1, !proto->canWriteNoResponse());
      Serial.println("[GATT] Protocol Mode <- 0x01 (Report)");
    }
    if (proto->canRead()) hexDumpString("[GATT] Protocol Mode after", proto->readValue());
  }

  std::map<uint16_t, BLERemoteCharacteristic *> *byHandle = hid->getCharacteristicsByHandle();
  if (!byHandle) {
    Serial.println("[GATT] HID getCharacteristicsByHandle FAILED");
    return;
  }

  int reportCount = 0;
  for (auto &kv : *byHandle) {
    BLERemoteCharacteristic *c = kv.second;
    if (!c->getUUID().equals(kChar2A4D)) continue;
    reportCount++;

    String refHex = "";
    std::map<std::string, BLERemoteDescriptor *> *descs = c->getDescriptors();
    if (descs) {
      for (auto &dk : *descs) {
        BLERemoteDescriptor *d = dk.second;
        if (d->getUUID().equals(kDesc2908)) {
          String v = d->readValue();
          refHex = v;
          hexDump(
            "[GATT] Report Reference",
            (const uint8_t *)v.c_str(),
            v.length()
          );
          // byte0 = Report ID, byte1 = type (1=Input 2=Output 3=Feature)
          if (v.length() >= 2) {
            uint8_t rid = (uint8_t)v[0];
            uint8_t rtype = (uint8_t)v[1];
            rememberReport(c->getHandle(), rid);
            Serial.printf(
              "[GATT] Report h=0x%04X id=0x%02X type=%u\n",
              c->getHandle(),
              rid,
              rtype
            );
          }
        }
      }
    }

    char label[32];
    snprintf(label, sizeof(label), "Report#%d", reportCount);
    tryNotify(c, label);
    if (c->canRead()) {
      String v = c->readValue();
      hexDump(
        "[GATT] Report read",
        (const uint8_t *)v.c_str(),
        v.length()
      );
    }
    (void)refHex;
  }
  Serial.printf("[GATT] HID Report characteristics found: %d\n", reportCount);
}

static bool connectAndProbe() {
  if (!gHaveTarget || !gTargetAddr) return false;

  if (gClient) {
    if (gClient->isConnected()) gClient->disconnect();
    delete gClient;
    gClient = nullptr;
  }

  gClient = BLEDevice::createClient();
  gClient->setClientCallbacks(new ClientCB());

  Serial.printf(
    "[GAP] connecting to %s type=%u …\n",
    gTargetAddr->toString().c_str(),
    (unsigned)gTargetAddrType
  );
  if (!gClient->connect(*gTargetAddr, gTargetAddrType)) {
    Serial.println("[GAP] connect FAILED");
    return false;
  }

  // Finish Legacy JW: Confirm → Random → Encrypt (Mac stalls after Pairing Response).
  Serial.println("[SMP] secureConnection() …");
  bool secured = gClient->secureConnection();
  Serial.printf("[SMP] secureConnection -> %s\n", secured ? "ok" : "FAIL/timeout");

  // Prefer a more patient supervision timeout than macOS's 720ms.
  if (gClient->updateConnParams(12, 24, 0, 400)) {
    Serial.println("[GAP] conn params requested (timeout≈4s)");
  }

  delay(200);

  Serial.println("[GATT] getServices …");
  std::map<std::string, BLERemoteService *> *services = gClient->getServices();
  if (!services) {
    Serial.println("[GATT] getServices FAILED");
    return true;
  }

  bool sawHID = false, sawD1 = false, sawD0 = false;
  for (auto &kv : *services) {
    BLERemoteService *svc = kv.second;
    dumpServiceByHandle(svc);
    if (svc->getUUID().equals(kSvcHID)) sawHID = true;
    if (svc->getUUID().equals(kSvcD1FF)) sawD1 = true;
    if (svc->getUUID().equals(kSvcD0FF)) sawD0 = true;
  }
  Serial.printf("[GATT] summary HID=%d D1FF=%d D0FF=%d\n", sawHID, sawD1, sawD0);

  if (BLERemoteService *d1 = gClient->getService(kSvcD1FF)) {
    tryNotify(d1->getCharacteristic(kCharA001), "A001");
  }

  if (BLERemoteService *d0 = gClient->getService(kSvcD0FF)) {
    if (BLERemoteCharacteristic *fff1 = d0->getCharacteristic(kCharFFF1)) {
      if (fff1->canRead()) hexDumpString("[GATT] FFF1", fff1->readValue());
    }
  }

  if (BLERemoteService *hid = gClient->getService(kSvcHID)) {
    setupHID(hid);
  }

  Serial.println("BRIDGE STATUS holding");
  Serial.println("[RUN] holding link — BRIDGE HID lines go to Mac Studio");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(800);
  Serial.println();
  Serial.println("=== MR25GA ESP32 Legacy JW central (core 3.3 BLE) ===");
  Serial.println("BRIDGE STATUS boot");

  BLEDevice::init("MR25GA-JW");
  BLEDevice::setSecurityCallbacks(new SecurityCB());

  // Bonding=yes, MITM=no, SC=no → LE Legacy Just Works
  BLESecurity::setAuthenticationMode(true, false, false);
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);

  BLEScan *scan = BLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new ScanCB());
  scan->setInterval(1349);
  scan->setWindow(449);
  scan->setActiveScan(true);
  Serial.println("BRIDGE STATUS scanning");
  Serial.printf("[SCAN] looking for \"%s\" …\n", kTargetName);
  scan->start(0, false);
}

void loop() {
  if (gDoConnect) {
    gDoConnect = false;
    gRepCount = 0;
    if (!connectAndProbe()) {
      Serial.println("[RUN] connect failed — rescan");
      Serial.println("BRIDGE STATUS disconnected");
      gRescan = true;
    }
  }

  if (gRescan && !gConnected) {
    gRescan = false;
    delay(2000);
    Serial.println("BRIDGE STATUS scanning");
    Serial.println("[SCAN] restart …");
    BLEDevice::getScan()->start(0, false);
  }

  drainHIDQueue();

  if (gLinkUpMs) {
    uint32_t now = millis();
    if (now - gLastAliveLogMs >= 5000) {
      gLastAliveLogMs = now;
      float lived = (now - gLinkUpMs) / 1000.0f;
      Serial.printf("BRIDGE UP %.1f\n", lived);
    }
  }

  delay(5);
}
