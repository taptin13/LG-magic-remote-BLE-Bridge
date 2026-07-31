# Voice / Siri via LG Magic Remote MR25GA

## Available today (no mic stream)

In **MagicRemoteBLE**, assign the **Siri** preset (`key 0xFE`) to any key — default **AI** (`0x808B`).  
Press → the app opens Siri via `NSWorkspace`. Audio from the remote is not yet routed into the system mic.

## Long-term goal

Keep the mic on the remote → Mac opens Siri → remote mic audio becomes a Core Audio input (virtual mic).

## Planned architecture (GATT stack)

```
LG Remote ──BLE──► ESP32 (MR-Proxy) ──GATT / USB?──► MagicRemoteBLE
                         │                              ├── Siri (done)
                         │                              ├── VoiceDecoder (TBD)
                         │                              └── Virtual Mic (TBD)
                         └── motion/button already on GATT Event
```

- Motion/button: **Custom GATT** (no BLE HID to the Mac).
- Voice: prefer a stable bridge packet/serial path; dual-link BLE audio is the main bottleneck on WROOM-32.
- ESP **does not decode** the codec — forward / log only.

## Phases

| Phase | Work | Status |
|------:|------|--------|
| **0** | Key map → open Siri (`0xFE`) | Done |
| **1** | Detect mic / AI hold → log + (optional) `type=5` Voice start/stop packet | Not started |
| **2** | Reverse: start/stop mic on LG GATT (`A002` / vendor), codec, report ID | Not started |
| **3** | Audio framing → PCM decoder on Mac | Not started |
| **4** | Core Audio virtual mic + set default input on VOICE | Not started |
| **5** | (Optional) measure ESP→Mac bitrate over BLE vs USB Serial | Not started |

## LG GATT (needs probing)

| UUID | Suspected role |
|------|----------------|
| `D1FF` / `A001` | notify — mainly report `0xFD` motion |
| `D1FF` / `A002` | write — candidate start/stop voice |
| `D0FF` / … | vendor — probe while holding mic |

## Virtual mic (Phase 4)

Siri reads **Core Audio input**, not an app buffer:

- Audio Server Plug-in / AudioDriverKit → virtual device
- `VOICE start` → set default input → Siri → push PCM
- `VOICE stop` → drain → restore previous mic

## Notes

WROOM-32 is enough for the current bridge. Measure bitrate before choosing BLE GATT vs USB UART for voice streaming.
