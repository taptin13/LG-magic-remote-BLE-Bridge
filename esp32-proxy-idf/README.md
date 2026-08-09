# MR-Proxy (ESP-IDF + NimBLE)

Does not use Arduino `BLEDevice.h`. Stack: **ESP-IDF → NimBLE**, dual-role.

```
LG Remote (Peripheral) ← Central — ESP32 — Peripheral → Mac (Custom GATT)
                              Event Bus
```

## Build / Flash

```bash
cd esp32-proxy-idf
pio run
pio run -t upload
pio device monitor -b 115200
```

Requires [PlatformIO](https://platformio.org/) (`pio`). First run downloads ESP-IDF + toolchain.

## Boot flow

1. ADV name **`MR-Proxy`**
2. Mac connect → ESP requests bond (Just Works) → encrypted link
3. Mac subscribe Event → ready → SCAN burst `LGE MR25GA`
4. Pair/bond remote → HID FD → Event Bus → GATT notify Mac

If the proxy is moved to another Mac and the old Mac bond is stale, release the
ESP32 BOOT button after power-on, then hold BOOT for 3 seconds. Firmware
deletes Mac bonds while preserving the cached LG remote bond, then advertises
again. The proxy is a custom GATT device, so it may not appear in macOS
Bluetooth Settings for a **Forget** action.

Command write requires encryption. After reflash: forget `MR-Proxy` on Mac if bond is stale.

## Module (`main/`)

| File | Role |
|------|------|
| `main.c` | Boot, NimBLE, Command `0x01`/`0x02` |
| `mac_gatt.c` | Peripheral — proxy service |
| `remote_manager.c` | Central — remote state machine |
| `remote_decoder.c` | FD → motion / wheel / button |
| `event_bus.c` | FreeRTOS queue |
| `mac_bridge.c` | Bus → notify Mac |

UUID / packet / key codes: [PROTOCOL.md](../PROTOCOL.md) · architecture: [ARCHITECTURE.md](../ARCHITECTURE.md).
