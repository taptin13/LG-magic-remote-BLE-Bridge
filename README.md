# MagicRemote BLE Bridge

Dùng LG Magic Remote **MR25GA** làm chuột bay + bàn phím trên Mac qua ESP32 dual-role proxy.

```
MR25GA (BLE Peripheral)
        ▲
   ESP32 Central
        │
   Event Bus  →  Custom GATT Notify
        │
   ESP32 Peripheral  (`MR-Proxy`)
        ▼
MagicRemoteBLE → CGEvent (chuột / phím / scroll / Siri)
```

## Thành phần active

| | Path |
|---|---|
| Mac app | [`MagicRemoteBLE/`](MagicRemoteBLE/) |
| Firmware | [`esp32-proxy-idf/`](esp32-proxy-idf/) (ESP-IDF + NimBLE, PlatformIO) |
| Xcode | `MagicRemoteBLEBridge.xcodeproj` → scheme **MagicRemoteBLE** |
| Bundle ID | `com.vuong.magicremote.ble2` |

Dự án cũ: [`legacy/`](legacy/).

## Chạy nhanh

```bash
# 1. Flash ESP32
cd esp32-proxy-idf && pio run -t upload && pio device monitor -b 115200

# 2. Build / chạy Mac app
xcodebuild -scheme MagicRemoteBLE -configuration Debug build
# hoặc mở .xcodeproj → Run MagicRemoteBLE
```

1. Cấp **Bluetooth** + **Accessibility** cho app (System Settings).
2. App scan → chọn **`MR-Proxy`** → Connect (bond lần đầu).
3. Bấm nút trên remote nếu ESP đang SCAN `LGE MR25GA`.
4. Status `ready` → bật Input mapping; gán **Mouse toggle** / **Siri** trong bảng map nếu cần.

## Tính năng Mac (tóm tắt)

- Airmouse + wheel scroll (Natural Scroll tùy chọn)
- Map phím MR25GA → HID / media / **Siri** (`0xFE`) / **Mouse toggle** (`0xFD`)
- **Mouse mode ON:** motion di chuyển chuột; Wheel/OK = trái; Settings = phải; Back = nút Back chuột
- Pointer overlay (mũi tên phóng to) khi remote đang điều khiển
- Calib / độ nhạy airmouse gửi xuống ESP qua Command char

## Tài liệu

| File | Nội dung |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Kiến trúc ESP + Mac (baseline) |
| [PROTOCOL.md](PROTOCOL.md) | GATT UUID, packet, lệnh, mã phím |
| [BASELINE.md](BASELINE.md) | Baseline đã test + tag |
| [docs/TEST_MATRIX.md](docs/TEST_MATRIX.md) | Test matrix thực tế |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [VOICE.md](VOICE.md) | Kế hoạch voice / mic → Siri |
| [esp32-proxy-idf/README.md](esp32-proxy-idf/README.md) | Build / flash firmware |
| [legacy/README.md](legacy/README.md) | Dự án cũ |

## CI

GitHub Actions (`.github/workflows/ci.yml`): PlatformIO build, host unit tests, Xcode Debug (unsigned).

```bash
cd esp32-proxy-idf/tests/host && make test
```

Version hiện tại: xem [`VERSION`](VERSION).

