# MagicRemote BLE Bridge

Use an **LG Magic Remote** as an air mouse + keyboard on a Mac, via a small ESP32 BLE proxy.

```
LG Magic Remote (BLE Peripheral)
        ▲
   ESP32 Central
        │
    Event Bus  →  Custom GATT Notify
        │
   ESP32 Peripheral  (`MR-Proxy`)
        ▼
MagicRemoteBLE → CGEvent (mouse / keys / scroll / Siri)
```

Tested baseline: **LG Magic Remote MR25GA** (`LGE MR25GA`). Other LG Magic Remotes that advertise a name containing `LGE MR` usually work at the radio layer; button layouts are configured with JSON **profiles** (see [Adding another LG remote](#adding-another-lg-remote)).

## What you need

| Item | Notes |
|------|--------|
| Mac | macOS with Bluetooth (tested on recent macOS / Sequoia) |
| ESP32 DevKit | Classic ESP32 (D0WD), USB serial (often CH340 → `/dev/cu.wchusbserial*`) |
| LG Magic Remote | Prefer MR25GA; other `LGE MR…` models: add a profile |
| Tools | [Xcode](https://developer.apple.com/xcode/), [PlatformIO CLI](https://platformio.org/) (`pio`) |

## Active components

| | Path |
|---|---|
| Mac app | [`MagicRemoteBLE/`](MagicRemoteBLE/) |
| Firmware | [`esp32-proxy-idf/`](esp32-proxy-idf/) (ESP-IDF + NimBLE, PlatformIO) |
| Profiles | [`MagicRemoteBLE/Profiles/`](MagicRemoteBLE/Profiles/) |
| Xcode | `MagicRemoteBLEBridge.xcodeproj` → scheme **MagicRemoteBLE** |
| Bundle ID | `com.vuong.magicremote.ble2` |

## Quick start

### 1. Flash the ESP32

```bash
cd esp32-proxy-idf
pio run -t upload --upload-port /dev/cu.wchusbserial210   # adjust port
# optional: pio device monitor -b 115200
```

If upload fails at high baud, retry with:

```bash
UPLOAD_SPEED=115200 pio run -t upload --upload-port /dev/cu.YOURPORT
```

After a reflash, if Mac pairing breaks: **System Settings → Bluetooth → Forget `MR-Proxy`**, then connect again from the app.

### 2. Build / run the Mac app

```bash
# Xcode
open MagicRemoteBLEBridge.xcodeproj
# Scheme: MagicRemoteBLE → Run
```

Or:

```bash
xcodebuild -scheme MagicRemoteBLE -configuration Debug build
```

### 3. Permissions

In **System Settings → Privacy & Security**:

1. **Bluetooth** — allow MagicRemoteBLE  
2. **Accessibility** — allow MagicRemoteBLE (required to inject mouse/keyboard)

### 4. Connect

1. Power the ESP32; it advertises **`MR-Proxy`**.
2. In the app, enable **Auto-connect** (or Scan → select `MR-Proxy` → Connect).
3. Accept the BLE bond on first connect (Just Works).
4. When status shows the ESP is scanning / connecting to the remote, **press any button on the Magic Remote**.
5. Wait until status is **`ready`**.
6. Turn **Map** ON. For air mouse, turn **Mouse** ON.
7. After connect / reconnect, **hold the remote still ~0.5s** so gyro bias can lock (avoids a drifting cursor). Then point normally.

## Daily use

| Feature | How |
|---------|-----|
| Air mouse | Mouse mode ON; tilt the remote |
| Left / right / Back click | Mouse ON: Wheel/OK, Settings, Back (profile defaults) |
| Key mapping | Key Mapping screen — pick profile, assign HID / media / Siri |
| Mouse toggle / Siri | Special map keys `0xFD` / `0xFE` (see [PROTOCOL.md](PROTOCOL.md)) |
| Pointer size | Pointer Options (system cursor scale when available) |
| Sensitivity | Airmouse sliders (sent to ESP when Ready) |
| Recalibrate gyro | Command `0x01` / UI path that resets bias — hold still afterward |
| Menu bar | App can run as menu-bar accessory; open window from the status item |

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `Peer removed pairing information` after flash | Forget **MR-Proxy** in Bluetooth settings, Connect again |
| Buttons/scroll work, cursor dead after reconnect | Hold remote **still** ~0.5s (gyro calibration), then move |
| Cursor runs by itself after reconnect | Same — wait for calib / still window; do not skip bias lock |
| Mac disconnect: *“connection has timed out unexpectedly”* | Update to latest firmware + app (link keepalive). Keep ESP powered; check RSSI / interference from other Bluetooth devices |
| ESP not found | Confirm USB power, `pio device monitor` shows ADV `MR-Proxy`, Bluetooth on |
| Remote never pairs | Put remote near ESP, press a button while status is `scan remote` / `remote connecting` |
| No mouse/keys | Accessibility granted; Map ON; Mouse ON for motion |

## Adding another LG remote

Firmware already accepts advertisement names that **equal `LGE MR25GA`** or **contain `LGE MR`**. Many Magic Remotes reuse similar HID report layouts; differences are usually **BLE local name** and **button codes**.

### A. Mac profile only (most LG Magic Remotes)

1. Copy [`MagicRemoteBLE/Profiles/lg-mr25ga.json`](MagicRemoteBLE/Profiles/lg-mr25ga.json) to e.g. `lg-mr18ga.json` (or drop into Application Support — see below).
2. Change:
   - `id` — unique slug (`lg-mr18ga`)
   - `displayName` — shown in the UI
   - `match.bleNameContains` — substrings of the remote’s BLE name (e.g. `["MR18GA", "LGE MR"]`)
   - `buttons` / `defaultMaps` / `pad` / `mouseBindings` — codes and layout for that model
3. Ship in the app target **or** drop-in:

   ```
   ~/Library/Application Support/MagicRemoteBLE/Profiles/*.json
   ```

   Same `id` overrides the bundled file. Restart the app, then select the profile in **Key Mapping**.

4. Discover unknown codes: enable Map, press each key, watch the log / last-button UI, fill `buttons` and `defaultMaps`.

Details: [`MagicRemoteBLE/Profiles/README.md`](MagicRemoteBLE/Profiles/README.md).

### B. Firmware name filter (rare)

If the remote’s BLE name does **not** contain `LGE MR` and is not `LGE MR25GA`, edit the matcher in [`esp32-proxy-idf/main/remote_manager.c`](esp32-proxy-idf/main/remote_manager.c) (and optionally `REMOTE_NAME` in [`config.h`](esp32-proxy-idf/main/config.h)), then reflash.

If the HID/FD payload format differs from MR25GA, you also need decoder changes in `remote_decoder.c` — that is advanced; open an issue with nRF Connect captures if you need help.

### Suggested workflow for a new model

1. Confirm the remote appears in nRF Connect / LightBlue as a BLE HID device; note the **advertised name**.
2. Flash stock firmware; connect Mac → `MR-Proxy`; see if ESP reaches **ready** when you press a remote button.
3. If Ready: create a profile JSON and map codes (no firmware change).
4. If ESP never sees the remote: update the name filter (B) and reflash.
5. If Ready but buttons are wrong codes: learn codes from the app log and fix the profile.

## Docs

| File | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | ESP + Mac architecture |
| [PROTOCOL.md](PROTOCOL.md) | GATT UUIDs, packets, commands, key codes |
| [MagicRemoteBLE/Profiles/README.md](MagicRemoteBLE/Profiles/README.md) | Profile JSON schema & drop-in path |
| [BASELINE.md](BASELINE.md) | Tested baseline + tag |
| [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md) | Real-world test matrix |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [VOICE.md](VOICE.md) | Voice / mic → Siri plan |
| [esp32-proxy-idf/README.md](esp32-proxy-idf/README.md) | Firmware build / flash |

## CI / tests

GitHub Actions (`.github/workflows/ci.yml`): PlatformIO build, host unit tests, unsigned Xcode Debug build.

```bash
cd esp32-proxy-idf/tests/host && make test
```

Current version: see [`VERSION`](VERSION).
