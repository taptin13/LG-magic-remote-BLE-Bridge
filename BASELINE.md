# Baseline v0.1.0-rc1

Ngày khóa: **2026-07-31**  
Tag: `v0.1.0-rc1`

## Đã verify trên máy dev

| Thành phần | Cách verify |
|------------|-------------|
| Firmware | `pio run -t upload --upload-port /dev/cu.wchusbserial10` |
| Mac app | `xcodebuild -scheme MagicRemoteBLE -configuration Debug` + `open …/MagicRemoteBLE.app` |
| Serial | Boot → MacReady → WaitingForRemote → Scanning/Connecting |
| Bugfix khi baseline | Không downgrade `MacReady` → `EventSubscribed` |

## Artifact nguồn

- Firmware: `esp32-proxy-idf/` (ESP-IDF 5.3 / PlatformIO espressif32 6.9)
- App: `MagicRemoteBLE/` bundle `com.vuong.magicremote.ble2`
- Docs: `ARCHITECTURE.md`, `PROTOCOL.md`, `docs/TEST_MATRIX.md`

## Ghi chú bond

Sau reflash ESP, nếu Mac báo lỗi pair: System Settings → Bluetooth → Forget **MR-Proxy**, Connect lại trong app.
