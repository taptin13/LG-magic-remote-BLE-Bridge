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

(The Mac app still knows legacy HID UUID `6D520002-…` — unused on the current stack.)

## Event packet (`bridge_packet_t`, little-endian)

```
[0]     type   1=Motion 2=Button 3=Battery 4=Status  (5=Voice — reserved on Mac)
[1]     seq
[2..]   payload
```

### Motion (type=1)

| Offset | Field |
|-------:|-------|
| 2–3 | `int16 dx` |
| 4–5 | `int16 dy` |
| 6–7 | `uint16 buttons` (bit0=L bit1=R — ESP currently sends 0; clicks use type=2) |
| 8 | `int8 wheel` (optional; scroll-only frames may have dx=dy=0) |

### Button (type=2)

`uint16 code` (BE on LG wire, LE in bridge packet), `uint8 down`

### Battery / Status

`uint8` at offset 2.

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
| `0x01` | — | Reset / recalibrate gyro bias |
| `0x02` | 3× `float32` LE: sens, thresh, softDead | Set air-mouse sensitivity |

Decoder defaults: sens `0.045`, thresh `280`, softDead `28`.

## Flow

1. Mac connects to `MR-Proxy` + **bond (Just Works)** + subscribe Event  
2. ESP treats Mac as **ready** only when Event CCCD is on **and** the link is encrypted  
3. SCAN `LGE MR25GA` (press a remote button if needed)  
4. Event stream → Mac `InputMapper` → CGEvent  

## Security (Mac ↔ ESP32)

| Component | Protection |
|-----------|------------|
| Command write | GATT `WRITE_ENC` + `sec_state.encrypted` check in callback |
| Ready / scan remote | Only after subscribe **and** encryption |
| Event / Status notify | Sent on a paired link (Just Works, no MITM PIN) |

Threat model: block a nearby unpaired BLE device from writing CMD / enabling the bridge.  
Does not stop an attacker with physical access or an already-paired peer. Disable with `-DPROXY_REQUIRE_MAC_ENC=0` for debug.

After an **ESP reflash**: if the Mac reports a bond error (`Peer removed pairing information`), System Settings → Bluetooth → Forget **MR-Proxy**, then Connect again.

## MR25GA key codes (mapped in the app)

| Code | Name | Default map |
|------|------|-------------|
| `0x8002` | Vol+ | Media Vol+ |
| `0x8003` | Vol- | Media Vol- |
| `0x8007` / `0x8006` | Left / Right | ← / → |
| `0x8040` / `0x8041` | Up / Down | ↑ / ↓ |
| `0x80A1` | Input | — |
| `0x8045` | 123 | — |
| `0x8028` | Back | Esc (Mouse ON → mouse Back) |
| `0x8043` | Settings | — (Mouse ON → right click) |
| `0x8044` | Wheel/OK | Enter (Mouse ON → left click) |
| `0x80AB` | Guide/List | — |
| `0x807C` | Home | ⌘H |
| `0x8029` | Help | — |
| `0x8056`…`0x800C` | B1–B6 | — |
| `0x808B` | AI | Siri (`key 0xFE`) |

Special presets (not real HID usages):

| key | Meaning |
|----:|---------|
| `0xFE` | Open Siri |
| `0xFD` | Toggle mouse mode |
| `0xF1` / `0xF2` / `0xF3` | Media Vol+ / Vol- / Mute |

Source of truth: `MagicRemoteBLE/Models.swift`, `esp32-proxy-idf/main/bridge_packet.h`.
