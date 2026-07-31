/**
 * MagicRemote BLE Bridge — ESP32 dual-role
 *
 *   Peripheral  → Mac  (service 6D520001-…, HID notify)
 *   Central     → LGE MR25GA (Legacy Just Works bond + HID)
 *
 * Arduino ESP32 core 3.3.x (BLEDevice / NimBLE). Serial 115200 = debug only.
 */

#include <Arduino.h>
#include <map>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include <BLEClient.h>
#include <BLEServer.h>
#include <BLESecurity.h>
#include <BLE2902.h>

static const char *kAdvName = "MR-BLE-Bridge";
static const char *kTargetName = "LGE MR25GA";

static BLEUUID kSvcBridge("6D520001-4D52-3235-4741-425249444745");
static BLEUUID kCharHID("6D520002-4D52-3235-4741-425249444745");
static BLEUUID kCharStatus("6D520003-4D52-3235-4741-425249444745");

static BLEUUID kSvcD1FF("0000D1FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcD0FF("0000D0FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcHID((uint16_t)0x1812);
static BLEUUID kCharA001((uint16_t)0xA001);
static BLEUUID kCharFFF1((uint16_t)0xFFF1);
static BLEUUID kChar2A4A((uint16_t)0x2A4A);
static BLEUUID kChar2A4B((uint16_t)0x2A4B);
static BLEUUID kChar2A4D((uint16_t)0x2A4D);
static BLEUUID kChar2A4E((uint16_t)0x2A4E);
static BLEUUID kDesc2908((uint16_t)0x2908);

enum : uint8_t {
  ST_BOOT = 0,
  ST_SCANNING = 1,
  ST_REMOTE_CONN = 2,
  ST_HOLDING = 3,
  ST_REMOTE_DISC = 4,
  ST_MAC_SUB = 5,
};

static BLEAddress *gTargetAddr = nullptr;
static uint8_t gTargetAddrType = 0;
static bool gHaveTarget = false;
static bool gDoConnect = false;
static bool gRescan = false;
static bool gRemoteConnected = false;
static uint32_t gLinkUpMs = 0;
static BLEClient *gClient = nullptr;

static BLEServer *gServer = nullptr;
static BLECharacteristic *gHidChar = nullptr;
static BLECharacteristic *gStatusChar = nullptr;
static bool gMacConnected = false;
static uint8_t gStatus = ST_BOOT;


static const int kMaxReports = 16;
static uint16_t gRepHandles[kMaxReports];
static uint8_t gRepIds[kMaxReports];
static int gRepCount = 0;

struct HidFrame {
  uint8_t reportId;
  uint8_t len;
  uint8_t data[32];
};
static const int kHidQ = 96;
static HidFrame gHidQ[kHidQ];
static volatile int gHidHead = 0;
static volatile int gHidTail = 0;
static portMUX_TYPE gHidMux = portMUX_INITIALIZER_UNLOCKED;

static void rememberReport(uint16_t handle, uint8_t reportId) {
  for (int i = 0; i < gRepCount; i++) {
    if (gRepHandles[i] == handle) { gRepIds[i] = reportId; return; }
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

static void setStatus(uint8_t s) {
  gStatus = s;
  if (gStatusChar) {
    gStatusChar->setValue(&gStatus, 1);
    if (gMacConnected) gStatusChar->notify();
  }
  Serial.printf("[STATUS] %u\n", s);
}

static void enqueueHID(uint8_t reportId, const uint8_t *data, size_t len) {
  if (len > 32) len = 32;
  portENTER_CRITICAL(&gHidMux);
  int next = (gHidHead + 1) % kHidQ;
  if (next != gHidTail) {
    HidFrame &f = gHidQ[gHidHead];
    f.reportId = reportId;
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

    // Packet for Mac: [reportId][payload…] — keep ≤20 for default MTU
    uint8_t pkt[21];
    uint8_t n = f.len;
    if (n > 19) n = 19;
    pkt[0] = f.reportId;
    memcpy(pkt + 1, f.data, n);
    if (gHidChar && gMacConnected) {
      gHidChar->setValue(pkt, (size_t)n + 1);
      gHidChar->notify();
    }
  }
}

static void notifyCB(BLERemoteCharacteristic *c, uint8_t *data, size_t len, bool isNotify) {
  (void)isNotify;
  enqueueHID(reportIdForHandle(c->getHandle()), data, len);
}

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    (void)s;
    gMacConnected = true;
    Serial.println("[MAC] connected");
    setStatus(ST_MAC_SUB);
  }
  void onDisconnect(BLEServer *s) override {
    (void)s;
    gMacConnected = false;
    Serial.println("[MAC] disconnected — advertising");
    BLEDevice::startAdvertising();
  }
};

class SecurityCB : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  void onPassKeyNotify(uint32_t) override {}
  bool onConfirmPIN(uint32_t) override { return true; }
  bool onSecurityRequest() override { return true; }
  bool onAuthorizationRequest(uint16_t, uint16_t, bool) override { return true; }
#if defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t cmpl) override {
    Serial.printf("[SMP] auth success=%d reason=0x%x\n", cmpl.success, cmpl.fail_reason);
  }
#endif
#if defined(CONFIG_NIMBLE_ENABLED)
  void onAuthenticationComplete(ble_gap_conn_desc *desc) override {
    if (!desc) return;
    Serial.printf(
      "[SMP] enc=%d auth=%d bond=%d\n",
      desc->sec_state.encrypted,
      desc->sec_state.authenticated,
      desc->sec_state.bonded
    );
  }
#endif
};

class ClientCB : public BLEClientCallbacks {
  void onConnect(BLEClient *) override {
    gRemoteConnected = true;
    gLinkUpMs = millis();
    Serial.println("[REMOTE] connected");
    setStatus(ST_REMOTE_CONN);
  }
  void onDisconnect(BLEClient *) override {
    Serial.println("[REMOTE] disconnected");
    gRemoteConnected = false;
    gLinkUpMs = 0;
    gRescan = true;
    setStatus(ST_REMOTE_DISC);
  }
};

class ScanCB : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice d) override {
    if (!d.haveName() || d.getName() != kTargetName) return;
    Serial.printf("[SCAN] found %s rssi=%d\n", d.getName().c_str(), d.getRSSI());
    BLEDevice::getScan()->stop();
    if (gTargetAddr) delete gTargetAddr;
    gTargetAddr = new BLEAddress(d.getAddress());
    gTargetAddrType = d.getAddressType();
    gHaveTarget = true;
    gDoConnect = true;
  }
};

static bool tryNotify(BLERemoteCharacteristic *c, const char *label) {
  if (!c || (!c->canNotify() && !c->canIndicate())) return false;
  c->registerForNotify(notifyCB);
  Serial.printf("[GATT] notify %s h=0x%04X\n", label, c->getHandle());
  return true;
}

static void setupHID(BLERemoteService *hid) {
  if (BLERemoteCharacteristic *proto = hid->getCharacteristic(kChar2A4E)) {
    uint8_t reportMode = 0x01;
    if (proto->canWrite() || proto->canWriteNoResponse()) {
      proto->writeValue(&reportMode, 1, !proto->canWriteNoResponse());
    }
  }

  auto *byHandle = hid->getCharacteristicsByHandle();
  if (!byHandle) return;
  int n = 0;
  for (auto &kv : *byHandle) {
    BLERemoteCharacteristic *c = kv.second;
    if (!c->getUUID().equals(kChar2A4D)) continue;
    n++;
    if (auto *descs = c->getDescriptors()) {
      for (auto &dk : *descs) {
        BLERemoteDescriptor *d = dk.second;
        if (d->getUUID().equals(kDesc2908)) {
          String v = d->readValue();
          if (v.length() >= 1) rememberReport(c->getHandle(), (uint8_t)v[0]);
        }
      }
    }
    char label[24];
    snprintf(label, sizeof(label), "R#%d", n);
    tryNotify(c, label);
  }
  Serial.printf("[GATT] HID reports=%d\n", n);
}

static bool connectRemote() {
  if (!gHaveTarget || !gTargetAddr) return false;
  if (gClient) {
    if (gClient->isConnected()) gClient->disconnect();
    delete gClient;
    gClient = nullptr;
  }
  gClient = BLEDevice::createClient();
  gClient->setClientCallbacks(new ClientCB());
  Serial.printf("[REMOTE] connecting %s …\n", gTargetAddr->toString().c_str());
  if (!gClient->connect(*gTargetAddr, gTargetAddrType)) {
    Serial.println("[REMOTE] connect FAIL");
    return false;
  }

  bool secured = gClient->secureConnection();
  Serial.printf("[SMP] secureConnection -> %s\n", secured ? "ok" : "FAIL");
  gClient->updateConnParams(12, 24, 0, 400);
  delay(200);

  if (BLERemoteService *d1 = gClient->getService(kSvcD1FF)) {
    tryNotify(d1->getCharacteristic(kCharA001), "A001");
  }
  if (BLERemoteService *hid = gClient->getService(kSvcHID)) {
    setupHID(hid);
  }
  setStatus(ST_HOLDING);
  Serial.println("[RUN] holding — HID → Mac GATT");
  return true;
}

static void startBridgeServer() {
  gServer = BLEDevice::createServer();
  gServer->setCallbacks(new ServerCB());

  BLEService *svc = gServer->createService(kSvcBridge);

  gHidChar = svc->createCharacteristic(
    kCharHID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  gHidChar->addDescriptor(new BLE2902());

  gStatusChar = svc->createCharacteristic(
    kCharStatus,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  gStatusChar->addDescriptor(new BLE2902());
  gStatusChar->setValue(&gStatus, 1);

  svc->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(kSvcBridge);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  BLEDevice::startAdvertising();
  Serial.println("[MAC] advertising as MR-BLE-Bridge");
}

void setup() {
  Serial.begin(115200);
  delay(600);
  Serial.println();
  Serial.println("=== MagicRemote BLE Bridge (dual-role) ===");

  BLEDevice::init(kAdvName);
  BLEDevice::setSecurityCallbacks(new SecurityCB());
  BLESecurity::setAuthenticationMode(true, false, false);
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);

  startBridgeServer();
  setStatus(ST_BOOT);

  BLEScan *scan = BLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new ScanCB());
  scan->setInterval(1349);
  scan->setWindow(449);
  scan->setActiveScan(true);
  setStatus(ST_SCANNING);
  Serial.printf("[SCAN] looking for \"%s\" …\n", kTargetName);
  scan->start(0, false);
}

void loop() {
  if (gDoConnect) {
    gDoConnect = false;
    gRepCount = 0;
    if (!connectRemote()) {
      setStatus(ST_REMOTE_DISC);
      gRescan = true;
    }
  }

  if (gRescan && !gRemoteConnected) {
    gRescan = false;
    delay(1500);
    setStatus(ST_SCANNING);
    BLEDevice::getScan()->start(0, false);
  }

  drainHIDQueue();
  delay(4);
}
