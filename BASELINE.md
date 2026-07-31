# Baseline v0.1.0-rc1

Freeze date: **2026-07-31**  
Tag: `v0.1.0-rc1`

## Verified on the development machine

| Component | How verified |
|-----------|--------------|
| Firmware | `pio run -t upload --upload-port /dev/cu.wchusbserial10` |
| Mac app | `xcodebuild -scheme MagicRemoteBLE -configuration Debug` + `open …/MagicRemoteBLE.app` |
| Serial | Boot → MacReady → WaitingForRemote → Scanning/Connecting |
| Bug fixed at baseline | Do not downgrade `MacReady` → `EventSubscribed` |

## Source artifacts

- Firmware: `esp32-proxy-idf/` (ESP-IDF 5.3 / PlatformIO espressif32 6.9)
- App: `MagicRemoteBLE/` bundle `com.vuong.magicremote.ble2`
- Docs: `ARCHITECTURE.md`, `PROTOCOL.md`, `docs/TEST_MATRIX.md`

## Bond note

After an ESP reflash, if the Mac reports a pairing error: System Settings → Bluetooth → Forget **MR-Proxy**, then Connect again in the app.
