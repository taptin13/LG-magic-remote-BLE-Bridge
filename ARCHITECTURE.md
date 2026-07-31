# Kiến trúc MR-Proxy (product) — baseline v0.1.0-rc1

ESP32 dual-role — **không** dùng BLE HID tới Mac. Mac chỉ thấy custom GATT `MR-Proxy`.

## Topology (implementation hiện tại)

```
LG Remote (LGE MR25GA)
   │ BLE notify (report 0xFD)
   ▼
remote_manager (GAP central) ──ble_core_cmd_*──► BleCoreTask
   │ raw FD
   ▼
remote_decoder → event_bus → mac_bridge → ble_core_submit_packet
                                              │
                    bridge_state (SoT)         │
                    bridge_metrics             ▼
                                         TX mutex + motion latest
                                         + button queue + pending_rel
                                              │
                                              ▼
                                    mac_gatt notify Event
                                              │
                                              ▼
                                 MagicRemoteBLE / InputMapper / CGEvent
```

## Nguyên tắc đã triển khai

1. **Một BLE owner** — `BleCoreTask` thực thi GAP / GATTC / SM inject / Event+Status notify. Host callback chỉ enqueue (`ble_disc_evt_t` / cmd queue).
2. **State SoT** — `bridge_state` (Mac / Remote / Overall). `remote_manager` không còn `RM_*` song song; dùng `REM_*` qua `bridge_state_set_remote`.
3. **Session generation** — `ble_disc_ctx_t {conn, conn_gen, disc_gen}`; mismatch → ignore + metric.
4. **Channels** — motion latest-value; button/status queue; `s_pending_rel` cho synthetic release; toàn bộ `s_tx_q` dưới `s_tx_mu`.
5. **Decoder độc lập** — `remote_decoder_on_fd` → event_bus (host-testable).
6. **Recovery** — deadline scan / connect / security / discovery + reconnect backoff.
7. **Security** — Mac CMD encrypted + `isfinite` trên float CMD.
8. **Fault injection** — `bridge_fault` (`-DBRIDGE_FAULT_INJECT=1`); host tests + optional TX drop/overflow.

## State machines

### Mac
`Advertising → Connected → Encrypted → EventSubscribed → MacReady`  
(Không downgrade sau MacReady khi CCCD event lặp.)

### Remote (`remote_link_state_t`)
`Idle | WaitMac → Scanning → Connecting → Encrypted → Discovering → RemoteReady`  
`Recovering` khi drop / timeout.

### Overall
`WaitingForMac → WaitingForRemote → Streaming` / `Recovering`

## Module layout

```
esp32-proxy-idf/main/
  ble_core.*            BleCoreTask, cmd/evt/TX
  bridge_state.*        SoT Mac/Remote/Overall + sessions
  bridge_metrics.*      counters (HB log)
  bridge_packet.*       validate / parse / encode
  bridge_fault.*        fault-injection hooks
  transport_channels.*  typed publish API
  remote_manager.*      remote link + discovery SM
  mac_gatt.*            GATT + ADV/notify raw (owner-only)
  remote_decoder.*      FD IMU/button
  mac_bridge.*          event_bus → submit_packet
  event_bus.*           producer bus
  ble_tx.*              thin wrapper → ble_core

esp32-proxy-idf/tests/host/   host unit tests (make test)
.github/workflows/ci.yml      PIO + host tests + Xcode
```

## Lộ trình

| Phase | Nội dung | Status |
|------:|----------|--------|
| 1–4 | TX / BleCore / session / channels | Done |
| 5 | Metrics + deadlines + pending_rel + TX mutex | Done |
| 6 | Packet validate API (+ version field later) | Partial |
| 7 | bridge_state SoT (hết RM_*) | Done |
| 8 | LPF / CI tuning | Later |
| 9 | Full GATTC-only-on-owner + GAP event enqueue | Done (ops); notify RX decode still on host |

## Baseline / CI

- Tag: xem `VERSION`, `BASELINE.md`, `CHANGELOG.md`
- Test matrix: [`docs/TEST_MATRIX.md`](docs/TEST_MATRIX.md)
- CI: PlatformIO build, host `make test`, Xcode `CODE_SIGNING_ALLOWED=NO`

## Mac app

| File | Vai trò |
|------|---------|
| `BLEBridgeHost.swift` | Scan→Connect, bond, prefs |
| `InputMapper.swift` | CGEvent, mouse mode, releaseAll |
| `AppModel.swift` | Prefs |
| `BridgeUUIDs.swift` | Packet parse |

## Legacy

[`legacy/`](legacy/) — Studio, HID dongle, Arduino proxy, `MRDongleConfig`.
