# GATT protocol — Mac ↔ ESP32 MR-Proxy

ESP32 advertises: **`MR-Proxy`**  
Remote target: **`LGE MR25GA`**

## UUIDs

| Role | UUID |
|------|------|
| Service | `6D520001-4D52-3235-4741-425249444745` |
| Event notify | `6D520010-4D52-3235-4741-425249444745` |
| Status notify/read | `6D520003-4D52-3235-4741-425249444745` |
| Command write | `6D520012-4D52-3235-4741-425249444745` |

(Mac còn giữ UUID HID legacy `6D520002-…` — không dùng trên stack hiện tại.)

## Event packet (`bridge_packet_t`, little-endian)

```
[0]     type   1=Motion 2=Button 3=Battery 4=Status  (5=Voice — reserved Mac)
[1]     seq
[2..]   payload
```

### Motion (type=1)

| Offset | Field |
|-------:|-------|
| 2–3 | `int16 dx` |
| 4–5 | `int16 dy` |
| 6–7 | `uint16 buttons` (bit0=L bit1=R — hiện ESP gửi 0; click qua type=2) |
| 8 | `int8 wheel` (optional; frame chỉ scroll có thể dx=dy=0) |

### Button (type=2)

`uint16 code` (BE trên wire LG, LE trong packet bridge), `uint8 down`

### Battery / Status

`uint8` tại offset 2.

## Status byte

| Value | Meaning |
|------:|---------|
| 0 | boot |
| 1 | wait Mac |
| 2 | scan remote |
| 3 | remote connecting |
| 4 | ready |
| 5 | remote dropped |

## Command (Mac → ESP32)

| Byte0 | Payload | Meaning |
|------:|---------|---------|
| `0x01` | — | Reset / recalib gyro bias |
| `0x02` | 3× `float32` LE: sens, thresh, softDead | Đặt độ nhạy airmouse |

Mặc định decoder: sens `0.045`, thresh `280`, softDead `28`.

## Flow

1. Mac Connect `MR-Proxy` + **bond (Just Works)** + subscribe Event  
2. ESP chỉ coi Mac **ready** khi Event CCCD bật **và** link đã encrypted  
3. SCAN `LGE MR25GA` (bấm nút remote nếu cần)  
4. Event stream → Mac `InputMapper` → CGEvent  

## Security (Mac ↔ ESP32)

| Thành phần | Bảo vệ |
|------------|--------|
| Command write | GATT `WRITE_ENC` + kiểm tra `sec_state.encrypted` trong callback |
| Ready / scan remote | Chỉ sau subscribe **và** encryption |
| Event / Status notify | Gửi trên link đã pair (Just Works, không MITM PIN) |

Threat model: ngăn thiết bị BLE lạ ghi CMD / kích hoạt bridge mà không pair.  
Không chống attacker có physical access / đã pair. Tắt bằng `-DPROXY_REQUIRE_MAC_ENC=0` khi debug.

Sau **reflash ESP**: nếu Mac báo bond lỗi (`Peer removed pairing information`), System Settings → Bluetooth → quên **MR-Proxy**, rồi Connect lại.

## Mã phím MR25GA (đã map trong app)

| Code | Tên | Mặc định map |
|------|-----|--------------|
| `0x8002` | Vol+ | Media Vol+ |
| `0x8003` | Vol- | Media Vol- |
| `0x8007` / `0x8006` | Left / Right | ← / → |
| `0x8040` / `0x8041` | Up / Down | ↑ / ↓ |
| `0x80A1` | Input | — |
| `0x8045` | 123 | — |
| `0x8028` | Back | Esc (Mouse ON → mouse Back) |
| `0x8043` | Settings | — (Mouse ON → chuột phải) |
| `0x8044` | Wheel/OK | Enter (Mouse ON → chuột trái) |
| `0x80AB` | Guide/List | — |
| `0x807C` | Home | ⌘H |
| `0x8029` | Help | — |
| `0x8056`…`0x800C` | B1–B6 | — |
| `0x808B` | AI | Siri (`key 0xFE`) |

Preset đặc biệt (không phải HID usage thật):

| key | Ý nghĩa |
|----:|---------|
| `0xFE` | Mở Siri |
| `0xFD` | Bật/tắt mouse mode |
| `0xF1` / `0xF2` / `0xF3` | Media Vol+ / Vol- / Mute |

Nguồn sự thật: `MagicRemoteBLE/Models.swift`, `esp32-proxy-idf/main/bridge_packet.h`.
