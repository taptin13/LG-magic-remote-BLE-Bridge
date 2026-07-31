/**
 * MR-Dongle — Mac BLE HID + LGE MR25GA remote (dual-role)
 *
 * Phase A: Peripheral HID ↔ Mac (bond SC Just Works) — chờ MAC BONDED
 * Phase B: Stop ADV → Legacy JW central → remote → map FD → HID mouse/keys
 *
 * Arduino ESP32 core 3.3.x · Serial 115200
 *
 * 1. Upload
 * 2. Mac Forget "MRDongle2" → Connect "MRDongle3"
 * 3. Serial: MAC BONDED → SCAN remote (async) → REMOTE BONDED → rê = chuột
 * 4. Đã nhớ remote: sau reboot tự SCAN — bấm nút remote để đánh thức
 */

#include <Arduino.h>
#include <string.h>
#include <math.h>
#include <map>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLEHIDDevice.h>
#include <BLESecurity.h>
#include <BLEAddress.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>
#include <BLEClient.h>
#if defined(CONFIG_BLUEDROID_ENABLED)
#include <esp_gap_ble_api.h>
#endif

// Đổi tên khi đổi HID map → Mac hiện thiết bị mới (vẫn cần Forget bản cũ)
static const char *kHidName = "MRDongle3";
static const char *kRemoteName = "LGE MR25GA";

#define DBG(fmt, ...) Serial.printf("[%8lu] " fmt "\n", (unsigned long)millis(), ##__VA_ARGS__)

// --- Remote GATT ---
static BLEUUID kSvcD1FF("0000D1FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcD0FF("0000D0FF-3C17-D293-8E48-14FE2E4DA212");
static BLEUUID kSvcHID((uint16_t)0x1812);
static BLEUUID kCharA001((uint16_t)0xA001);
static BLEUUID kChar2A4D((uint16_t)0x2A4D);
static BLEUUID kChar2A4E((uint16_t)0x2A4E);
static BLEUUID kDesc2908((uint16_t)0x2908);

// Report ID 1 = keyboard, 2 = mouse, 3 = consumer (Vol+/Vol-/Mute bitfield — Mac ổn định)
static const uint8_t hidReportMap[] = {
  // Keyboard
  0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
  0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01, 0x05, 0x08,
  0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06, 0x75, 0x08, 0x15, 0x00,
  0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
  // Mouse
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
  0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01, 0x05, 0x01,
  0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0,
  // Consumer: bit0=Vol+ bit1=Vol- bit2=Mute
  0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03,
  0x09, 0xE9, 0x09, 0xEA, 0x09, 0xE2, 0x81, 0x02, 0x95, 0x05, 0x81, 0x01, 0xC0
};

enum Phase : uint8_t {
  PH_MAC_WAIT = 0,
  PH_MAC_SETTLE = 1,
  PH_REMOTE_SCAN = 2,
  PH_REMOTE_CONN = 3,
  PH_RUN = 4,
};

static BLEHIDDevice *gHid = nullptr;
static BLECharacteristic *gKbIn = nullptr;
static BLECharacteristic *gMsIn = nullptr;
static BLECharacteristic *gCcIn = nullptr;
static BLEServer *gServer = nullptr;
static BLEClient *gClient = nullptr;

static volatile bool gMacConnected = false;
static volatile bool gMacBonded = false;
static volatile bool gRemoteConnected = false;
static volatile bool gRemoteBonded = false;
static bool gHavePeer = false;
static bool gHaveTarget = false;
static bool gDoConnect = false;
static bool gRescan = false;
static bool gAdvOn = false;
static Phase gPhase = PH_MAC_WAIT;

static uint32_t gMacConnectMs = 0;
static uint32_t gMacBondedMs = 0;
static uint32_t gRemoteLinkMs = 0;
static uint32_t gLastHeartbeat = 0;
static uint32_t gLastSecRetry = 0;
static uint32_t gLastAlive = 0;
static uint32_t gFdCount = 0;
static uint32_t gMouseTx = 0;

#if defined(CONFIG_BLUEDROID_ENABLED)
static esp_bd_addr_t gMacAddr = {0};
#endif
#if defined(CONFIG_NIMBLE_ENABLED)
static uint16_t gMacConnHandle = 0xFFFF;
#endif

static BLEAddress *gTargetAddr = nullptr;
static uint8_t gTargetAddrType = 0;
static bool gSavedRemote = false;   // đã từng nối thành công (NVS)
static uint32_t gScanStartedMs = 0;
static Preferences gPrefs;

// Connect remote từ app: ngắt → (optional unbond) → SCAN async (không block loop)
static volatile bool gPairRemoteReq = false;
static uint32_t gPairRemoteMs = 0;
static bool gPairRemoteForget = false;  // true = xóa NVS + bond peer (pair lại)
static bool gPairRemoteUnbond = false;
#if defined(CONFIG_BLUEDROID_ENABLED)
static esp_bd_addr_t gPairUnbondAddr = {0};
#endif

static void clearSavedRemote() {
  gPrefs.begin("mrdongle", false);
  gPrefs.remove("raddr");
  gPrefs.remove("rtype");
  gPrefs.remove("paired");
  gPrefs.end();
  gSavedRemote = false;
  DBG("NVS remote cleared");
}

static void saveRemoteTarget() {
  // Lưu cờ paired + địa chỉ (best-effort). Reconnect thật = SCAN theo tên vì RPA đổi.
  String addr = "";
  uint8_t typ = gTargetAddrType;
  if (gClient && gClient->isConnected()) {
    BLEAddress peer = gClient->getPeerAddress();
    addr = peer.toString();
    typ = peer.getType();
    if (gTargetAddr) delete gTargetAddr;
    gTargetAddr = new BLEAddress(peer);
    gTargetAddrType = typ;
  } else if (gTargetAddr) {
    addr = gTargetAddr->toString();
  }
  gPrefs.begin("mrdongle", false);
  gPrefs.putBool("paired", true);
  if (addr.length() >= 11) {
    gPrefs.putString("raddr", addr);
    gPrefs.putUChar("rtype", typ);
  }
  gPrefs.end();
  gSavedRemote = true;
  DBG("NVS paired=1 addr=%s type=%u (reconnect sẽ SCAN theo tên)", addr.c_str(), (unsigned)typ);
}

static bool loadSavedRemote() {
  gPrefs.begin("mrdongle", true);
  bool paired = gPrefs.getBool("paired", false);
  String addr = gPrefs.getString("raddr", "");
  uint8_t typ = gPrefs.getUChar("rtype", 0);
  gPrefs.end();
  gSavedRemote = paired || addr.length() >= 11;
  if (addr.length() >= 11) {
    if (gTargetAddr) delete gTargetAddr;
    gTargetAddr = new BLEAddress(addr, typ);
    gTargetAddrType = typ;
    gHaveTarget = true;
    DBG("NVS loaded paired=%d addr=%s type=%u", (int)gSavedRemote, gTargetAddr->toString().c_str(), (unsigned)typ);
  } else if (gSavedRemote) {
    DBG("NVS paired=1 (không có addr — chỉ SCAN theo tên)");
  }
  return gSavedRemote;
}

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

// --- Airmouse state (port từ InputMapper) ---
static double gGyroLPF[3] = {0, 0, 0};
static double gGyroBias[3] = {0, 0, 0};
static double gBiasSum[3] = {0, 0, 0};
static int gBiasSamples = 0;
static bool gCalibrating = true;
static bool gPointerMode = false;
static double gPixelCarryX = 0, gPixelCarryY = 0;
static uint16_t gLastBtn = 0;
static uint8_t gHeldKey = 0;
static uint8_t gHeldMod = 0;
static uint8_t gMouseButtons = 0;  // bit0=L bit1=R

static const int kBiasWarmup = 60;
static const double kLpfAlpha = 0.42;
static const double kStillGate = 70.0;
static const uint16_t kBtnOK = 0x8044;        // chuột trái (cố định)
static const uint16_t kBtnSettings = 0x8043;  // chuột phải (cố định)
static const uint16_t kBtnVoice = 0x808B;     // mic / Siri
static const uint8_t kMouseLeft = 0x01;
static const uint8_t kMouseRight = 0x02;
// Consumer bits (report ID 3, 1 byte): bit0=Vol+ bit1=Vol- bit2=Mute
static const uint8_t kCcBitVolUp = 0x01;
static const uint8_t kCcBitVolDown = 0x02;
static const uint8_t kCcBitMute = 0x04;
static uint8_t gHeldConsumerBits = 0;
/// Số frame đứng yên liên tiếp trước khi bias-adapt mạnh hơn (chống trôi, không giết cảm giác rê).
static const int kStillFramesBeforeBias = 40;
static int gStillFrames = 0;

// Runtime config (Mac app qua Serial CFG …)
static double gSoftDead = 28.0;
static double gAirThresh = 280.0;
static double gSens = 0.045;
static bool gInvertY = false;
static bool gInvertX = false;
static bool gVoiceActive = false;
static uint32_t gAudPktCount = 0;
static uint32_t gAudLogLeft = 0;  // số dòng hex còn được log trong phiên voice


struct KeyOverride {
  uint16_t btn;
  uint8_t mod;
  uint8_t key;
  bool active;  // false = disabled (UNMAP)
};
static const int kMaxOverrides = 24;
static KeyOverride gOverrides[kMaxOverrides];
static int gOverrideCount = 0;

static String gSerialLine;

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

static void sendMouse(uint8_t buttons, int8_t dx, int8_t dy, int8_t wheel) {
  if (!gMacConnected || !gMacBonded || !gMsIn) return;
  uint8_t rpt[4] = {buttons, (uint8_t)dx, (uint8_t)dy, (uint8_t)wheel};
  gMsIn->setValue(rpt, sizeof(rpt));
  gMsIn->notify();
  gMouseTx++;
}

static void sendKeyboard(uint8_t mod, uint8_t key) {
  if (!gMacConnected || !gMacBonded || !gKbIn) return;
  uint8_t rpt[8] = {mod, 0, key, 0, 0, 0, 0, 0};
  gKbIn->setValue(rpt, sizeof(rpt));
  gKbIn->notify();
}

/// Consumer Control report ID 3: 1-byte bitfield (0 = release)
static void sendConsumerBits(uint8_t bits) {
  if (!gMacConnected || !gMacBonded || !gCcIn) {
    DBG("MEDIA skip (mac=%d bonded=%d cc=%d)", (int)gMacConnected, (int)gMacBonded, gCcIn ? 1 : 0);
    return;
  }
  uint8_t rpt[1] = {bits};
  gCcIn->setValue(rpt, sizeof(rpt));
  gCcIn->notify();
  DBG("MEDIA notify bits=0x%02X", bits);
}

static uint8_t consumerBitsForRemoteBtn(uint16_t code) {
  switch (code) {
    case 0x8002: return kCcBitVolUp;
    case 0x8003: return kCcBitVolDown;
    case 0x8009: return kCcBitMute;
    default: return 0;
  }
}

/// Sentinel từ app MAP: 0xF1 Vol+ / 0xF2 Vol- / 0xF3 Mute
static uint8_t consumerBitsForMappedKey(uint8_t key) {
  switch (key) {
    case 0xF1: return kCcBitVolUp;
    case 0xF2: return kCcBitVolDown;
    case 0xF3: return kCcBitMute;
    default: return 0;
  }
}

static void pulseConsumerBits(uint8_t bits) {
  if (!bits) return;
  sendConsumerBits(bits);
  gHeldConsumerBits = bits;
  delay(60);
  sendConsumerBits(0);
  gHeldConsumerBits = 0;
}

static void releaseKeys() {
  if (gHeldKey || gHeldMod) {
    sendKeyboard(0, 0);
    gHeldKey = 0;
    gHeldMod = 0;
  }
  if (gHeldConsumerBits) {
    sendConsumerBits(0);
    gHeldConsumerBits = 0;
  }
  if (gMouseButtons) {
    sendMouse(0, 0, 0, 0);
    gMouseButtons = 0;
  }
}

static void smpForMac() {
  BLESecurity::setAuthenticationMode(true, false, true);  // SC JW
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);
  DBG("SMP mode=MAC (bond+SC)");
}

static void smpForRemote() {
  BLESecurity::resetSecurity();
  BLESecurity::setAuthenticationMode(true, false, false);  // Legacy JW
  BLESecurity::setCapability(ESP_IO_CAP_NONE);
  BLESecurity::setInitEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setRespEncryptionKey(ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK);
  BLESecurity::setForceAuthentication(true);
  DBG("SMP mode=REMOTE (Legacy JW, SC=0)");
}

static void startSecurityNow(const char *why) {
  if (!gHavePeer) return;
  int rc = -1;
  bool ok = false;
#if defined(CONFIG_BLUEDROID_ENABLED)
  ok = BLESecurity::startSecurity(gMacAddr, &rc);
  DBG("startSecurity(%s) ok=%d rc=%d", why, (int)ok, rc);
#elif defined(CONFIG_NIMBLE_ENABLED)
  if (gMacConnHandle == 0xFFFF) return;
  ok = BLESecurity::startSecurity(gMacConnHandle, &rc);
  DBG("startSecurity(%s) handle=%u ok=%d rc=%d", why, gMacConnHandle, (int)ok, rc);
#else
  (void)why;
  (void)ok;
  (void)rc;
#endif
}

static void setAdv(bool on) {
  if (on == gAdvOn) return;
  if (on) {
    BLEDevice::startAdvertising();
    DBG("ADV on");
  } else {
    BLEDevice::stopAdvertising();
    DBG("ADV off");
  }
  gAdvOn = on;
}

static void resetAirmouse() {
  gCalibrating = true;
  gBiasSamples = 0;
  gBiasSum[0] = gBiasSum[1] = gBiasSum[2] = 0;
  gGyroLPF[0] = gGyroLPF[1] = gGyroLPF[2] = 0;
  gPixelCarryX = gPixelCarryY = 0;
  gStillFrames = 0;
  gPointerMode = false;
  gLastBtn = 0;
  releaseKeys();
  DBG("airmouse calib — giữ yên remote ~1s");
}

static double softAxis(double v) {
  // Soft knee giống MagicRemoteStudio InputMapper — mượt, không cắt cứng.
  double a = fabs(v);
  if (a <= gSoftDead) return 0;
  double s = (a - gSoftDead) / (a + gSoftDead);
  return copysign(s * a, v);
}

static void cfgReplyOK() {
  Serial.printf(
    "CFG OK SENS=%.4f THRESH=%.0f DEAD=%.0f INVERTY=%d INVERTX=%d LEARN=%d OVR=%d PTR=%d\n",
    gSens,
    gAirThresh,
    gSoftDead,
    (int)gInvertY,
    (int)gInvertX,
    (int)gLearnMode,
    gOverrideCount,
    (int)gPointerMode
  );
}

static int findOverride(uint16_t btn) {
  for (int i = 0; i < gOverrideCount; i++) {
    if (gOverrides[i].btn == btn) return i;
  }
  return -1;
}

static bool defaultMapButton(uint16_t code, uint8_t *mod, uint8_t *key) {
  *mod = 0;
  *key = 0;
  switch (code) {
    case 0x8040: *key = 0x52; return true;
    case 0x8041: *key = 0x51; return true;
    case 0x8006: *key = 0x4F; return true;
    case 0x8007: *key = 0x50; return true;
    case 0x8028: *key = 0x29; return true;
    case 0x8045: *key = 0x2C; return true;
    case 0x80B0: *key = 0x2C; return true;
    case 0x807C: *mod = 0x08; *key = 0x0B; return true;
    // 0x8044 OK / 0x8043 Settings = chuột L/R cố định — không map phím
    case 0x8010: *key = 0x27; return true;
    case 0x8011: *key = 0x1E; return true;
    case 0x8012: *key = 0x1F; return true;
    case 0x8013: *key = 0x20; return true;
    case 0x8014: *key = 0x21; return true;
    case 0x8015: *key = 0x22; return true;
    case 0x8016: *key = 0x23; return true;
    case 0x8017: *key = 0x24; return true;
    case 0x8018: *key = 0x25; return true;
    case 0x8019: *key = 0x26; return true;
    default: return false;
  }
}

static int8_t clampI8(double v) {
  if (v > 127) return 127;
  if (v < -127) return -127;
  return (int8_t)lround(v);
}

/// Consumer code → HID keyboard usage (+ optional GUI mod)
static bool mapButton(uint16_t code, uint8_t *mod, uint8_t *key) {
  if (code == kBtnOK || code == kBtnSettings) return false;  // chuột cố định
  int oi = findOverride(code);
  if (oi >= 0) {
    if (!gOverrides[oi].active) return false;
    *mod = gOverrides[oi].mod;
    *key = gOverrides[oi].key;
    return *key != 0;
  }
  return defaultMapButton(code, mod, key);
}

static uint8_t mouseBitForRemoteBtn(uint16_t code) {
  if (code == kBtnOK) return kMouseLeft;
  if (code == kBtnSettings) return kMouseRight;
  return 0;
}

static void dumpOverrides() {
  for (int i = 0; i < gOverrideCount; i++) {
    Serial.printf(
      "CFG MAP %04X %02X %02X %d\n",
      gOverrides[i].btn,
      gOverrides[i].mod,
      gOverrides[i].key,
      gOverrides[i].active ? 1 : 0
    );
  }
}

static void startRemoteScanOnly();  // forward — CFG CONNECTREMOTE

#if defined(CONFIG_BLUEDROID_ENABLED)
static bool bdAddrEq(const esp_bd_addr_t a, const esp_bd_addr_t b) {
  return memcmp(a, b, ESP_BD_ADDR_LEN) == 0;
}

static void removeBondAddr(const esp_bd_addr_t addr) {
  esp_err_t e = esp_ble_remove_bond_device((uint8_t *)addr);
  DBG("unbond %02X:%02X:%02X:%02X:%02X:%02X -> %s",
      addr[0], addr[1], addr[2], addr[3], addr[4], addr[5],
      e == ESP_OK ? "ok" : "err");
}

/// Xóa bond remote; giữ bond Mac đang nối.
static void removeNonMacBonds() {
  int n = esp_ble_get_bond_device_num();
  if (n <= 0) return;
  esp_ble_bond_dev_t *list = (esp_ble_bond_dev_t *)malloc(sizeof(esp_ble_bond_dev_t) * (size_t)n);
  if (!list) return;
  int got = n;
  if (esp_ble_get_bond_device_list(&got, list) != ESP_OK) {
    free(list);
    return;
  }
  for (int i = 0; i < got; i++) {
    if (gHavePeer && bdAddrEq(list[i].bd_addr, gMacAddr)) continue;
    removeBondAddr(list[i].bd_addr);
  }
  free(list);
}
#endif

/// Kết thúc yêu cầu Connect remote từ app (gọi trong loop, không trong Serial CB).
static void finishPairRemoteRequest() {
  BLEDevice::getScan()->stop();
  delay(50);

  if (gClient) {
    if (gClient->isConnected()) {
      gClient->disconnect();
      delay(200);
    }
    delete gClient;
    gClient = nullptr;
  }

  gRemoteConnected = false;
  gRemoteBonded = false;
  gRemoteLinkMs = 0;
  gHaveTarget = false;
  gDoConnect = false;
  gRescan = false;
  if (gTargetAddr) {
    delete gTargetAddr;
    gTargetAddr = nullptr;
  }

#if defined(CONFIG_BLUEDROID_ENABLED)
  if (gPairRemoteForget) {
    if (gPairRemoteUnbond) {
      removeBondAddr(gPairUnbondAddr);
      gPairRemoteUnbond = false;
    }
    removeNonMacBonds();
  }
#endif

  if (gPairRemoteForget) clearSavedRemote();
  releaseKeys();
  setAdv(false);
  smpForRemote();
  delay(100);
  startRemoteScanOnly();
  DBG("%s SCAN active — bấm nút remote%s",
      gPairRemoteForget ? "PAIR" : "RECONNECT",
      gPairRemoteForget ? " (pair mode nếu cần)" : " để đánh thức");
  Serial.println("CFG STATUS CONNECTREMOTE scanning");
  gPairRemoteForget = false;
}

static void handleCfgLine(String line) {
  line.trim();
  if (!line.startsWith("CFG ")) return;
  String cmd = line.substring(4);
  cmd.trim();

  if (cmd == "GET" || cmd == "STATUS") {
    cfgReplyOK();
    Serial.printf(
      "CFG STATUS ph=%u mac=%d/%d rem=%d/%d paired=%d fd=%lu mouseTx=%lu\n",
      (unsigned)gPhase,
      (int)gMacConnected,
      (int)gMacBonded,
      (int)gRemoteConnected,
      (int)gRemoteBonded,
      (int)gSavedRemote,
      (unsigned long)gFdCount,
      (unsigned long)gMouseTx
    );
    dumpOverrides();
    return;
  }
  if (cmd == "FORGETREMOTE" || cmd == "FORGET") {
    clearSavedRemote();
    Serial.println("CFG OK FORGETREMOTE");
    return;
  }
  if (cmd == "CONNECTREMOTE" || cmd == "PAIRREMOTE" || cmd == "SCANREMOTE") {
    if (!gMacConnected) {
      Serial.println("CFG ERR CONNECTREMOTE need Mac connected");
      return;
    }
    const bool forget = (cmd == "CONNECTREMOTE" || cmd == "PAIRREMOTE");
    gPairRemoteForget = forget;
#if defined(CONFIG_BLUEDROID_ENABLED)
    gPairRemoteUnbond = false;
    if (forget) {
      if (gClient && gClient->isConnected()) {
        BLEAddress peer = gClient->getPeerAddress();
        memcpy(gPairUnbondAddr, peer.getNative(), ESP_BD_ADDR_LEN);
        gPairRemoteUnbond = true;
      } else if (gTargetAddr) {
        memcpy(gPairUnbondAddr, gTargetAddr->getNative(), ESP_BD_ADDR_LEN);
        gPairRemoteUnbond = true;
      }
    }
#endif
    if (forget) {
      clearSavedRemote();
      gHaveTarget = false;
    }
    gRescan = false;
    gDoConnect = false;
    gPairRemoteReq = true;
    gPairRemoteMs = millis();
    BLEDevice::getScan()->stop();
    if (gClient && gClient->isConnected()) {
      DBG("%s — disconnect remote…", forget ? "PAIRREMOTE" : "SCANREMOTE");
      gClient->disconnect();
    } else if (!gRemoteConnected) {
      // Không có remote — SCAN ngay
      gPairRemoteReq = false;
      finishPairRemoteRequest();
      return;
    }
    Serial.printf("CFG OK %s\n", forget ? "CONNECTREMOTE" : "SCANREMOTE");
    DBG("%s queued", forget ? "PAIRREMOTE" : "SCANREMOTE");
    return;
  }
  if (cmd == "CALIB") {
    resetAirmouse();
    Serial.println("CFG OK CALIB");
    return;
  }
  if (cmd == "TESTVOL" || cmd == "TESTVOL+") {
    DBG("TESTVOL+ → bits=0x%02X", kCcBitVolUp);
    pulseConsumerBits(kCcBitVolUp);
    Serial.println("CFG OK TESTVOL");
    return;
  }
  if (cmd == "TESTVOL-") {
    DBG("TESTVOL- → bits=0x%02X", kCcBitVolDown);
    pulseConsumerBits(kCcBitVolDown);
    Serial.println("CFG OK TESTVOL");
    return;
  }
  if (cmd == "TESTMUTE") {
    DBG("TESTMUTE → bits=0x%02X", kCcBitMute);
    pulseConsumerBits(kCcBitMute);
    Serial.println("CFG OK TESTMUTE");
    return;
  }
  if (cmd.startsWith("SENS ")) {
    gSens = constrain(cmd.substring(5).toFloat(), 0.005f, 0.5f);
    cfgReplyOK();
    return;
  }
  if (cmd.startsWith("THRESH ")) {
    gAirThresh = constrain(cmd.substring(7).toFloat(), 20.0f, 2000.0f);
    cfgReplyOK();
    return;
  }
  if (cmd.startsWith("DEAD ")) {
    gSoftDead = constrain(cmd.substring(5).toFloat(), 0.0f, 200.0f);
    cfgReplyOK();
    return;
  }
  if (cmd.startsWith("INVERTY ")) {
    gInvertY = cmd.substring(8).toInt() != 0;
    cfgReplyOK();
    return;
  }
  if (cmd.startsWith("INVERTX ")) {
    gInvertX = cmd.substring(8).toInt() != 0;
    cfgReplyOK();
    return;
  }
  if (cmd.startsWith("LEARN ")) {
    gLearnMode = cmd.substring(6).toInt() != 0;
    Serial.printf("CFG OK LEARN=%d\n", (int)gLearnMode);
    return;
  }
  if (cmd == "MAPCLR") {
    gOverrideCount = 0;
    Serial.println("CFG OK MAPCLR");
    return;
  }
  if (cmd.startsWith("UNMAP ")) {
    uint16_t btn = (uint16_t)strtoul(cmd.substring(6).c_str(), nullptr, 16);
    if (btn == kBtnOK || btn == kBtnSettings) {
      Serial.printf("CFG ERR UNMAP %04X fixed mouse\n", btn);
      return;
    }
    int oi = findOverride(btn);
    if (oi < 0 && gOverrideCount < kMaxOverrides) {
      oi = gOverrideCount++;
      gOverrides[oi].btn = btn;
    }
    if (oi >= 0) {
      gOverrides[oi].btn = btn;
      gOverrides[oi].mod = 0;
      gOverrides[oi].key = 0;
      gOverrides[oi].active = false;
      Serial.printf("CFG OK UNMAP %04X\n", btn);
    } else {
      Serial.println("CFG ERR UNMAP full");
    }
    return;
  }
  if (cmd.startsWith("MAP ")) {
    // CFG MAP <btnHex> <modHex> <keyHex>
    char *p = const_cast<char *>(cmd.c_str() + 4);
    while (*p == ' ') p++;
    uint16_t btn = (uint16_t)strtoul(p, &p, 16);
    uint8_t mod = (uint8_t)strtoul(p, &p, 16);
    uint8_t key = (uint8_t)strtoul(p, &p, 16);
    if (btn == kBtnOK || btn == kBtnSettings) {
      Serial.printf("CFG ERR MAP %04X fixed mouse\n", btn);
      return;
    }
    int oi = findOverride(btn);
    if (oi < 0) {
      if (gOverrideCount >= kMaxOverrides) {
        Serial.println("CFG ERR MAP full");
        return;
      }
      oi = gOverrideCount++;
    }
    gOverrides[oi] = {btn, mod, key, true};
    Serial.printf("CFG OK MAP %04X -> mod=%02X key=%02X\n", btn, mod, key);
    return;
  }

  Serial.println("CFG ERR unknown");
}

static void pollSerialCfg() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (gSerialLine.length() > 0) {
        handleCfgLine(gSerialLine);
        gSerialLine = "";
      }
    } else if (gSerialLine.length() < 160) {
      gSerialLine += c;
    } else {
      gSerialLine = "";
    }
  }
}

static void handleFD(const uint8_t *p, size_t len) {
  if (len < 19 || !gMacBonded) return;
  gFdCount++;

  int16_t imu[6];
  for (int i = 0; i < 6; i++) {
    uint16_t raw = ((uint16_t)p[4 + i * 2] << 8) | p[5 + i * 2];
    imu[i] = (int16_t)raw;
  }
  uint16_t btn = ((uint16_t)p[16] << 8) | p[17];
  int8_t wheel = (int8_t)p[18];

  double gx = imu[0], gy = imu[1], gz = imu[2];
  (void)gy;

  if (gCalibrating) {
    gBiasSum[0] += gx;
    gBiasSum[1] += gy;
    gBiasSum[2] += gz;
    gBiasSamples++;
    if (gBiasSamples >= kBiasWarmup) {
      gGyroBias[0] = gBiasSum[0] / gBiasSamples;
      gGyroBias[1] = gBiasSum[1] / gBiasSamples;
      gGyroBias[2] = gBiasSum[2] / gBiasSamples;
      gCalibrating = false;
      gGyroLPF[0] = gGyroLPF[1] = gGyroLPF[2] = 0;
      DBG("gyro bias gx=%.0f gy=%.0f gz=%.0f — move remote", gGyroBias[0], gGyroBias[1], gGyroBias[2]);
    }
  } else {
    double cx = gx - gGyroBias[0];
    double cy = gy - gGyroBias[1];
    double cz = gz - gGyroBias[2];

    // Bias: nhẹ khi gần đứng yên; mạnh hơn chỉ sau khi đứng yên đủ lâu → hết trôi mà vẫn mượt khi rê.
    if (fabs(cx) < kStillGate && fabs(cz) < kStillGate) {
      gStillFrames++;
      double b = 0.0015;
      if (gStillFrames >= kStillFramesBeforeBias) b = 0.012;
      gGyroBias[0] = (1 - b) * gGyroBias[0] + b * gx;
      gGyroBias[1] = (1 - b) * gGyroBias[1] + b * gy;
      gGyroBias[2] = (1 - b) * gGyroBias[2] + b * gz;
      cx = gx - gGyroBias[0];
      cy = gy - gGyroBias[1];
      cz = gz - gGyroBias[2];
    } else {
      gStillFrames = 0;
    }

    const double a = kLpfAlpha;
    gGyroLPF[0] = a * cx + (1 - a) * gGyroLPF[0];
    gGyroLPF[1] = a * cy + (1 - a) * gGyroLPF[1];
    gGyroLPF[2] = a * cz + (1 - a) * gGyroLPF[2];

    double sx = softAxis(gGyroLPF[2]) * gSens;
    double sy = softAxis(gGyroLPF[0]) * gSens;
    if (gInvertX) sx = -sx;
    if (gInvertY) sy = -sy;
    if (fabs(gGyroLPF[0]) > gAirThresh || fabs(gGyroLPF[2]) > gAirThresh) gPointerMode = true;

    // Luôn integrate (giống Studio) — mượt; chỉ xóa carry khi cả hai trục = 0.
    if (sx == 0.0 && sy == 0.0) {
      gPixelCarryX = gPixelCarryY = 0;
    } else {
      gPixelCarryX += sx;
      gPixelCarryY += sy;
      int idx = (int)trunc(gPixelCarryX);
      int idy = (int)trunc(gPixelCarryY);
      gPixelCarryX -= idx;
      gPixelCarryY -= idy;
      while (idx != 0 || idy != 0) {
        int8_t dx = clampI8(idx);
        int8_t dy = clampI8(idy);
        idx -= dx;
        idy -= dy;
        sendMouse(gMouseButtons, dx, dy, 0);
      }
    }
  }

  if (wheel != 0) {
    if (gPointerMode) {
      sendMouse(gMouseButtons, 0, 0, wheel);
    } else {
      uint8_t key = wheel > 0 ? 0x52 : 0x51;
      sendKeyboard(0, key);
      delay(12);
      sendKeyboard(0, 0);
    }
  }

  if (btn == gLastBtn) return;
  uint16_t prev = gLastBtn;
  gLastBtn = btn;

  if (btn != 0) {
    Serial.printf("CFG BTN %04X\n", btn);
    if (btn == kBtnVoice) {
      gVoiceActive = true;
      gAudPktCount = 0;
      gAudLogLeft = 80;  // capture ~80 frame đầu khi giữ mic
      Serial.println("CFG VOICE 1");
      DBG("VOICE DOWN — capture non-FD HID reports");
    }
    if (gLearnMode) {
      Serial.printf("CFG LEARNED %04X\n", btn);
      gLearnMode = false;
      Serial.println("CFG OK LEARN=0");
    }
  } else {
    Serial.println("CFG BTN 0000");
  }

  if (prev != 0) {
    if (prev == kBtnVoice) {
      gVoiceActive = false;
      Serial.printf("CFG VOICE 0 pkts=%lu\n", (unsigned long)gAudPktCount);
      DBG("VOICE UP pkts=%lu", (unsigned long)gAudPktCount);
    }
    if (uint8_t bit = mouseBitForRemoteBtn(prev)) {
      gMouseButtons &= (uint8_t)~bit;
      sendMouse(gMouseButtons, 0, 0, 0);
    } else if (prev != kBtnVoice) {
      releaseKeys();
    }
  }
  if (btn != 0) {
    if (btn == kBtnVoice) {
      // Siri kích hoạt phía Mac qua Serial CFG VOICE — không map HID key
    } else if (uint8_t bit = mouseBitForRemoteBtn(btn)) {
      // OK = trái, Settings = phải — luôn chuột, không phụ thuộc pointer mode
      gMouseButtons |= bit;
      sendMouse(gMouseButtons, 0, 0, 0);
      DBG("BTN 0x%04X → mouse 0x%02X", btn, gMouseButtons);
    } else if (uint8_t cb = consumerBitsForRemoteBtn(btn)) {
      DBG("BTN 0x%04X → consumer bits=0x%02X", btn, cb);
      pulseConsumerBits(cb);
    } else {
      uint8_t mod = 0, key = 0;
      if (mapButton(btn, &mod, &key)) {
        if (uint8_t cb = consumerBitsForMappedKey(key)) {
          DBG("BTN 0x%04X → mapped media bits=0x%02X", btn, cb);
          pulseConsumerBits(cb);
        } else {
          sendKeyboard(mod, key);
          gHeldMod = mod;
          gHeldKey = key;
          DBG("BTN 0x%04X → key=0x%02X mod=0x%02X", btn, key, mod);
        }
      } else {
        DBG("BTN 0x%04X (unmapped)", btn);
      }
    }
  }
}

static void logAudFrame(uint8_t reportId, const uint8_t *data, size_t len) {
  if (!gVoiceActive || reportId == 0xFD || len == 0) return;
  gAudPktCount++;
  if (gAudLogLeft == 0) return;
  gAudLogLeft--;
  Serial.printf("CFG AUD %02X %u ", reportId, (unsigned)len);
  size_t n = len > 24 ? 24 : len;
  for (size_t i = 0; i < n; i++) Serial.printf("%02X", data[i]);
  if (len > n) Serial.print("…");
  Serial.println();
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

    logAudFrame(f.reportId, f.data, f.len);

    if (f.reportId == 0xFD && f.len >= 19) {
      handleFD(f.data, f.len);
    }
  }
}

static void notifyCB(BLERemoteCharacteristic *c, uint8_t *data, size_t len, bool isNotify) {
  (void)isNotify;
  enqueueHID(reportIdForHandle(c->getHandle()), data, len);
}

class ServerCB : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    gMacConnected = true;
    gMacBonded = false;
    gMacConnectMs = millis();
    gMacBondedMs = 0;
    DBG("MAC CONNECT connCount=%d", s ? s->getConnectedCount() : -1);
  }

#if defined(CONFIG_BLUEDROID_ENABLED)
  void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    gMacConnected = true;
    gMacBonded = false;
    gMacConnectMs = millis();
    gMacBondedMs = 0;
    if (param) {
      memcpy(gMacAddr, param->connect.remote_bda, sizeof(esp_bd_addr_t));
      gHavePeer = true;
      DBG("MAC CONNECT conn_id=%u addr=%s", param->connect.conn_id, BLEAddress(gMacAddr).toString().c_str());
      startSecurityNow("onConnect");
    }
    (void)s;
  }
#endif

#if defined(CONFIG_NIMBLE_ENABLED)
  void onConnect(BLEServer *s, ble_gap_conn_desc *desc) override {
    gMacConnected = true;
    gMacBonded = false;
    gMacConnectMs = millis();
    gMacBondedMs = 0;
    gMacConnHandle = desc ? desc->conn_handle : 0xFFFF;
    gHavePeer = (gMacConnHandle != 0xFFFF);
    DBG("MAC CONNECT handle=%u", gMacConnHandle);
    if (desc && !desc->sec_state.encrypted) startSecurityNow("onConnect");
    else if (desc && desc->sec_state.encrypted) {
      gMacBonded = true;
      gMacBondedMs = millis();
      DBG("MAC BONDED (already)");
    }
    (void)s;
  }
#endif

  void onDisconnect(BLEServer *s) override {
    gMacConnected = false;
    gMacBonded = false;
    gHavePeer = false;
#if defined(CONFIG_NIMBLE_ENABLED)
    gMacConnHandle = 0xFFFF;
#endif
    gMacConnectMs = 0;
    gMacBondedMs = 0;
    releaseKeys();
    DBG("MAC DISCONNECT — pause remote, ADV again");
    // Prefer Mac recovery: stop scanning, keep remote if already up
    if (gPhase == PH_REMOTE_SCAN || gPhase == PH_MAC_SETTLE) {
      BLEDevice::getScan()->stop();
    }
    gPhase = PH_MAC_WAIT;
    smpForMac();
    delay(80);
    setAdv(true);
    (void)s;
  }
};

class SecurityCB : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  void onPassKeyNotify(uint32_t) override {}
  bool onConfirmPIN(uint32_t) override { return true; }
  bool onSecurityRequest() override {
    DBG("SMP security request -> accept");
    return true;
  }
  bool onAuthorizationRequest(uint16_t, uint16_t, bool) override { return true; }
#if defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t cmpl) override {
    DBG("SMP auth success=%d reason=0x%x", cmpl.success, cmpl.fail_reason);
    if (!cmpl.success) return;
    if (gMacConnected && !gMacBonded) {
      gMacBonded = true;
      gMacBondedMs = millis();
      DBG("MAC BONDED");
    } else if (gRemoteConnected) {
      gRemoteBonded = true;
      DBG("REMOTE BONDED");
    }
  }
#endif
#if defined(CONFIG_NIMBLE_ENABLED)
  void onAuthenticationComplete(ble_gap_conn_desc *desc) override {
    if (!desc) {
      DBG("SMP auth fail (null)");
      return;
    }
    DBG("SMP enc=%d bond=%d handle=%u", desc->sec_state.encrypted, desc->sec_state.bonded, desc->conn_handle);
    if (!desc->sec_state.encrypted) return;
    if (gMacConnected && !gMacBonded) {
      gMacBonded = true;
      gMacBondedMs = millis();
#if defined(CONFIG_NIMBLE_ENABLED)
      gMacConnHandle = desc->conn_handle;
#endif
      DBG("MAC BONDED");
    } else if (gRemoteConnected) {
      gRemoteBonded = true;
      DBG("REMOTE BONDED");
    }
  }
#endif
};

class ClientCB : public BLEClientCallbacks {
  void onConnect(BLEClient *) override {
    gRemoteConnected = true;
    gRemoteBonded = false;
    gRemoteLinkMs = millis();
    DBG("REMOTE CONNECT");
  }
  void onDisconnect(BLEClient *) override {
    float lived = gRemoteLinkMs ? (millis() - gRemoteLinkMs) / 1000.0f : 0;
    DBG("REMOTE DISCONNECT lived=%.2fs", lived);
    gRemoteConnected = false;
    gRemoteBonded = false;
    gRemoteLinkMs = 0;
    releaseKeys();
    if (gPairRemoteReq) {
      // App Connect remote đang xử lý — không auto-rescan ở đây
      return;
    }
    if (gMacBonded) {
      gRescan = true;
      gPhase = PH_REMOTE_SCAN;
    }
  }
};

class ScanCB : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice d) override {
    if (gRemoteConnected || gPhase == PH_REMOTE_CONN) return;
    if (!d.haveName() || d.getName() != kRemoteName) return;
    DBG("SCAN found %s rssi=%d addr=%s", d.getName().c_str(), d.getRSSI(), d.getAddress().toString().c_str());
    if (gTargetAddr) delete gTargetAddr;
    gTargetAddr = new BLEAddress(d.getAddress());
    gTargetAddrType = d.getAddressType();
    gHaveTarget = true;
    gDoConnect = true;
    gRescan = false;
    BLEDevice::getScan()->stop();
  }
};
static ScanCB gScanCB;

static bool tryNotify(BLERemoteCharacteristic *c, const char *label) {
  if (!c || (!c->canNotify() && !c->canIndicate())) return false;
  c->registerForNotify(notifyCB);
  DBG("GATT notify %s h=0x%04X", label, c->getHandle());
  return true;
}

static void setupRemoteHID(BLERemoteService *hid) {
  if (BLERemoteCharacteristic *proto = hid->getCharacteristic(kChar2A4E)) {
    uint8_t reportMode = 0x01;
    if (proto->canWrite() || proto->canWriteNoResponse()) {
      proto->writeValue(&reportMode, 1, !proto->canWriteNoResponse());
      DBG("GATT Protocol Mode <- 0x01");
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
          if (v.length() >= 1) {
            rememberReport(c->getHandle(), (uint8_t)v[0]);
            DBG("GATT Report h=0x%04X id=0x%02X", c->getHandle(), (uint8_t)v[0]);
          }
        }
      }
    }
    char label[24];
    snprintf(label, sizeof(label), "R#%d", n);
    tryNotify(c, label);
  }
  DBG("GATT HID reports=%d", n);
}

static bool connectRemote() {
  if (!gHaveTarget || !gTargetAddr) return false;
  gPhase = PH_REMOTE_CONN;

  if (gClient) {
    if (gClient->isConnected()) gClient->disconnect();
    delete gClient;
    gClient = nullptr;
  }

  smpForRemote();
  delay(50);

  gClient = BLEDevice::createClient();
  gClient->setClientCallbacks(new ClientCB());
  DBG("REMOTE connecting %s type=%u …", gTargetAddr->toString().c_str(), (unsigned)gTargetAddrType);
  if (!gClient->connect(*gTargetAddr, gTargetAddrType)) {
    DBG("REMOTE connect FAIL");
    return false;
  }

  DBG("SMP secureConnection() …");
  bool secured = gClient->secureConnection();
  DBG("SMP secureConnection -> %s", secured ? "ok" : "FAIL/timeout");
  if (secured) {
    gRemoteBonded = true;
  } else {
    DBG("REMOTE secure FAIL — sẽ SCAN lại (giữ paired nếu đã nhớ)");
    gClient->disconnect();
    delay(100);
    delete gClient;
    gClient = nullptr;
    gRemoteConnected = false;
    return false;
  }

  gClient->updateConnParams(12, 24, 0, 400);
  delay(200);

  gRepCount = 0;
  if (BLERemoteService *d1 = gClient->getService(kSvcD1FF)) {
    tryNotify(d1->getCharacteristic(kCharA001), "A001");
  }
  if (BLERemoteService *hid = gClient->getService(kSvcHID)) {
    setupRemoteHID(hid);
  } else {
    DBG("GATT HID 1812 missing");
  }

  saveRemoteTarget();
  resetAirmouse();
  gPhase = PH_RUN;
  DBG("RUN — remote FD → Mac HID (NVS paired=1)");
  return true;
}

static void onRemoteScanComplete(BLEScanResults results) {
  (void)results;
  // Chỉ resume scan nếu vẫn đang chờ remote (chưa tìm thấy / chưa connect)
  if (gPhase == PH_REMOTE_SCAN && !gRemoteConnected && !gDoConnect && gMacBonded && !gPairRemoteReq) {
    gRescan = true;
  }
}

static void startRemoteScanOnly() {
  gPhase = PH_REMOTE_SCAN;
  gScanStartedMs = millis();
  BLEScan *scan = BLEDevice::getScan();
  scan->stop();
  delay(30);
  scan->setAdvertisedDeviceCallbacks(&gScanCB, true);
  // Duty cycle nhẹ hơn — dual-role với Mac peripheral
  scan->setInterval(160);
  scan->setWindow(48);
  scan->setActiveScan(true);
  if (gSavedRemote) {
    DBG("SCAN async reconnect \"%s\" — bấm nút remote để đánh thức", kRemoteName);
  } else {
    DBG("SCAN async pair \"%s\" — remote gần / pair mode nếu cần", kRemoteName);
  }
  // QUAN TRỌNG: start(duration, callback) = non-blocking.
  // start(0, false) là bản blocking forever → loop/Serial chết.
  if (!scan->start(3, onRemoteScanComplete, false)) {
    DBG("SCAN start failed — retry");
    gRescan = true;
  }
}

static void startRemoteScan() {
  setAdv(false);
  smpForRemote();
  // Không connect thẳng địa chỉ đã lưu: Magic Remote dùng RPA → addr đổi mỗi lần.
  // Bond keys (Bluedroid NVS) + SCAN theo tên = nhớ remote đúng nghĩa.
  startRemoteScanOnly();
}

static void startHidPeripheral() {
  gServer = BLEDevice::createServer();
  gServer->setCallbacks(new ServerCB());

  gHid = new BLEHIDDevice(gServer);
  gHid->manufacturer()->setValue("Vuong");
  // Đổi PID/version → Mac Forget MRDongle2 + Connect MRDongle3 (HID Vol bitfield mới)
  gHid->pnp(0x02, 0x05ac, 0x8211, 0x0301);
  gHid->hidInfo(0x00, 0x01);
  gHid->reportMap((uint8_t *)hidReportMap, sizeof(hidReportMap));
  gKbIn = gHid->inputReport(1);
  gMsIn = gHid->inputReport(2);
  gCcIn = gHid->inputReport(3);
  gHid->setBatteryLevel(100);
  gHid->startServices();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->setAppearance(HID_KEYBOARD);
  adv->addServiceUUID(gHid->hidService()->getUUID());
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMaxPreferred(0x12);
  setAdv(true);
  DBG("ADV \"%s\" — Connect Mac trước", kHidName);
}

void setup() {
  Serial.begin(115200);
  delay(800);
  Serial.println();
  Serial.println("========================================");
  DBG("BOOT MRDongle3 dual-role + Vol bitfield + async SCAN — Forget MRDongle2, Connect MRDongle3");
  Serial.println("========================================");

  BLEDevice::init(kHidName);
  BLEDevice::setSecurityCallbacks(new SecurityCB());

  BLESecurity *pSecurity = new BLESecurity();
  (void)pSecurity;
  smpForMac();

  startHidPeripheral();
  gPhase = PH_MAC_WAIT;
  loadSavedRemote();
  if (gSavedRemote) {
    DBG("ready — đã nhớ remote. Mac Connect rồi bấm 1 nút trên remote → tự nối");
  } else {
    DBG("ready — Mac Connect → nối remote lần đầu (sẽ nhớ)");
  }
}

void loop() {
  pollSerialCfg();

  // App: Connect remote — đợi remote drop rồi SCAN (tránh delete client khi đang notify)
  if (gPairRemoteReq) {
    bool idle = !gRemoteConnected && !(gClient && gClient->isConnected());
    uint32_t age = millis() - gPairRemoteMs;
    if (idle && age > 250) {
      gPairRemoteReq = false;
      finishPairRemoteRequest();
    } else if (age > 4000) {
      DBG("CONNECTREMOTE timeout — force SCAN");
      gPairRemoteReq = false;
      gRemoteConnected = false;
      finishPairRemoteRequest();
    }
  }

  // Mac SMP retry
  if (gMacConnected && !gMacBonded && gHavePeer && gMacConnectMs) {
    uint32_t age = millis() - gMacConnectMs;
    if (age > 1500 && millis() - gLastSecRetry > 2000) {
      gLastSecRetry = millis();
      BLESecurity::resetSecurity();
      startSecurityNow("retry");
    }
  }

  // Mac bonded → settle → scan remote theo tên (auto nếu đã paired)
  if (gPhase == PH_MAC_WAIT && gMacBonded) {
    if (gRemoteConnected) {
      gPhase = PH_RUN;
      DBG("MAC lại bonded — remote vẫn up → RUN");
    } else {
      gPhase = PH_MAC_SETTLE;
      DBG("MAC settled — %s", gSavedRemote ? "auto SCAN remote (đã nhớ)" : "SCAN remote lần đầu");
    }
  }
  if (gPhase == PH_MAC_SETTLE && gMacBonded && gMacBondedMs && (millis() - gMacBondedMs > 800)) {
    if (!gRemoteConnected) startRemoteScan();
    else gPhase = PH_RUN;
  }

  if (gDoConnect) {
    gDoConnect = false;
    if (!connectRemote()) {
      gRescan = true;
      gPhase = PH_REMOTE_SCAN;
    }
  }

  // Remote drop hoặc scan burst xong → SCAN lại
  if (gRescan && !gRemoteConnected && gMacBonded && !gPairRemoteReq) {
    gRescan = false;
    delay(350);
    DBG("SCAN lại…");
    smpForRemote();
    startRemoteScanOnly();
  }

  // Watchdog nếu scan state kẹt
  if (gPhase == PH_REMOTE_SCAN && !gRemoteConnected && gMacBonded && gScanStartedMs &&
      (millis() - gScanStartedMs > 15000)) {
    DBG("SCAN watchdog restart");
    BLEDevice::getScan()->stop();
    delay(80);
    startRemoteScanOnly();
  }

  drainHIDQueue();

  if (millis() - gLastHeartbeat >= 5000) {
    gLastHeartbeat = millis();
    DBG(
      "HB ph=%u mac=%d/%d rem=%d/%d fd=%lu mouseTx=%lu",
      (unsigned)gPhase,
      (int)gMacConnected,
      (int)gMacBonded,
      (int)gRemoteConnected,
      (int)gRemoteBonded,
      (unsigned long)gFdCount,
      (unsigned long)gMouseTx
    );
  }

  if (gRemoteLinkMs && millis() - gLastAlive >= 5000) {
    gLastAlive = millis();
    DBG("REMOTE UP %.1fs fd=%lu", (millis() - gRemoteLinkMs) / 1000.0f, (unsigned long)gFdCount);
  }

  delay(5);
}
