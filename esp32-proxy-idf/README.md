# MR-Proxy (ESP-IDF + NimBLE)

Không dùng Arduino `BLEDevice.h`. Stack: **ESP-IDF → NimBLE**, dual-role.

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

Cần [PlatformIO](https://platformio.org/) (`pio`). Lần đầu tải ESP-IDF + toolchain.

## Luồng boot

1. ADV tên **`MR-Proxy`**
2. Mac connect → ESP yêu cầu bond (Just Works) → encrypted link
3. Mac subscribe Event → ready → SCAN burst `LGE MR25GA`
4. Pair/bond remote → HID FD → Event Bus → GATT notify Mac

Command write cần encryption. Sau reflash: quên `MR-Proxy` trên Mac nếu bond lệch.

## Module (`main/`)

| File | Vai trò |
|------|---------|
| `main.c` | Boot, NimBLE, Command `0x01`/`0x02` |
| `mac_gatt.c` | Peripheral — service proxy |
| `remote_manager.c` | Central — state machine remote |
| `remote_decoder.c` | FD → motion / wheel / button |
| `event_bus.c` | FreeRTOS queue |
| `mac_bridge.c` | Bus → notify Mac |

UUID / packet / mã phím: [PROTOCOL.md](../PROTOCOL.md) · kiến trúc: [ARCHITECTURE.md](../ARCHITECTURE.md).
