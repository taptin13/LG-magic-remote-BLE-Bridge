# Voice / Siri qua LG Magic Remote MR25GA

## Hiện có (không cần mic stream)

Trong **MagicRemoteBLE**, gán preset **Siri** (`key 0xFE`) cho bất kỳ phím — mặc định **AI** (`0x808B`).  
Nhấn → app gọi `NSWorkspace` mở Siri. Chưa đưa audio từ remote vào mic hệ thống.

## Mục tiêu dài hạn

Giữ mic trên remote → Mac mở Siri → giọng từ mic remote thành input Core Audio (virtual mic).

## Kiến trúc dự kiến (cập nhật theo stack GATT)

```
LG Remote ──BLE──► ESP32 (MR-Proxy) ──GATT / USB?──► MagicRemoteBLE
                         │                              ├── Siri (đã có)
                         │                              ├── VoiceDecoder (TBD)
                         │                              └── Virtual Mic (TBD)
                         └── motion/button đã đi GATT Event
```

- Motion/button: **Custom GATT** (không còn BLE HID → Mac).
- Voice: ưu tiên bridge packet/serial ổn định; BLE dual-link audio là nghẽn chính trên WROOM-32.
- ESP **không decode** codec — chỉ forward / log.

## Phase

| Phase | Nội dung | Trạng thái |
|------:|----------|------------|
| **0** | Map phím → mở Siri (`0xFE`) | Xong |
| **1** | Detect giữ mic / AI → log + (tuỳ) packet `type=5` Voice start/stop | Chưa |
| **2** | Reverse: lệnh start/stop mic trên GATT LG (`A002` / vendor), codec, report ID | Chưa |
| **3** | Framing audio → decoder PCM trên Mac | Chưa |
| **4** | Core Audio virtual mic + set default input khi VOICE | Chưa |
| **5** | (Tuỳ chọn) đo bitrate ESP→Mac qua BLE vs USB Serial | Chưa |

## GATT LG (cần probe)

| UUID | Vai trò nghi ngờ |
|------|------------------|
| `D1FF` / `A001` | notify — chủ yếu report `0xFD` motion |
| `D1FF` / `A002` | write — ứng viên start/stop voice |
| `D0FF` / … | vendor — probe khi giữ mic |

## Virtual mic (Phase 4)

Siri đọc **Core Audio input**, không đọc buffer app:

- Audio Server Plug-in / AudioDriverKit → device ảo
- `VOICE start` → set default input → Siri → đẩy PCM
- `VOICE stop` → drain → restore mic cũ

## Ghi chú

WROOM-32 đủ cho bridge hiện tại. Voice stream cần đo bitrate trước khi chọn path BLE GATT vs USB UART.
