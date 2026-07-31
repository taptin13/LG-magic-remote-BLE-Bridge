# MagicRemote BLE Bridge

Use an LG Magic Remote **MR25GA** as an air mouse + keyboard on Mac via an ESP32 dual-role BLE proxy.

```
MR25GA (BLE Peripheral)
        ▲
   ESP32 Central
        │
    Event Bus  →  Custom GATT Notify
        │
   ESP32 Peripheral  (`MR-Proxy`)
        ▼
MagicRemoteBLE → CGEvent (mouse / keys / scroll / Siri)
```

## Active components

| | Path |
|---|---|
| Mac app | [`MagicRemoteBLE/`](MagicRemoteBLE/) |
| Firmware | [`esp32-proxy-idf/`](esp32-proxy-idf/) (ESP-IDF + NimBLE, PlatformIO) |
| Xcode | `MagicRemoteBLEBridge.xcodeproj` → scheme **MagicRemoteBLE** |
| Bundle ID | `com.vuong.magicremote.ble2` |

## Quick start

```bash
# 1. Flash ESP32
cd esp32-proxy-idf && pio run -t upload && pio device monitor -b 115200

# 2. Build / run Mac app
xcodebuild -scheme MagicRemoteBLE -configuration Debug build
# or open the .xcodeproj → Run MagicRemoteBLE
```

1. Grant **Bluetooth** + **Accessibility** to the app (System Settings).
2. App scans → select **`MR-Proxy`** → Connect (bond on first connect).
3. Press a button on the remote if the ESP is scanning for `LGE MR25GA`.
4. When status is `ready`, enable input mapping; assign **Mouse toggle** / **Siri** in the map table if needed.

## Mac features (summary)

- Air mouse + wheel scroll (optional Natural Scroll)
- Map MR25GA keys → HID / media / **Siri** (`0xFE`) / **Mouse toggle** (`0xFD`)
- **Mouse mode ON:** motion moves the cursor; Wheel/OK = left click; Settings = right click; Back = mouse Back
- Pointer overlay (enlarged arrow) while the remote is driving input
- Calibration / air-mouse sensitivity sent to the ESP via the Command characteristic

## Docs

| File | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | ESP + Mac architecture (baseline) |
| [PROTOCOL.md](PROTOCOL.md) | GATT UUIDs, packets, commands, key codes |
| [BASELINE.md](BASELINE.md) | Tested baseline + tag |
| [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md) | Real-world test matrix |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [VOICE.md](VOICE.md) | Voice / mic → Siri plan |
| [esp32-proxy-idf/README.md](esp32-proxy-idf/README.md) | Firmware build / flash |

## CI

GitHub Actions (`.github/workflows/ci.yml`): PlatformIO build, host unit tests, unsigned Xcode Debug build.

```bash
cd esp32-proxy-idf/tests/host && make test
```

Current version: see [`VERSION`](VERSION).
