# Test matrix (real-world)

Baseline environment: ESP32-D0WD-V3 + macOS + MagicRemoteBLE + remote `LGE MR25GA`.

| ID | Scenario | Steps | Expected | Baseline result |
|----|----------|-------|----------|-----------------|
| T1 | **Cold boot → Mac connect** | Flash/reset ESP → open app → Connect MR-Proxy | Serial: ADV → Connected → Encrypted → MacReady; overall WaitingForRemote; app bond OK | Pass (2026-07-31) |
| T2 | **Reconnect Mac** | Disconnect / kill app → open again → Connect | ESP keeps bond; MacReady again; remote need not re-pair if still up | Pass (auto reconnect after reflash) |
| T3 | **Reflash / bond mismatch** | `pio run -t upload` → app Connect | If `Peer removed pairing`: Forget MR-Proxy then Connect; CMD sens after ENC | Pass (Forget required when bond skews) |
| T4 | **Remote scan / reconnect** | MacReady + press a remote button | SCAN → CONNECT → ENC → Discover → READY / Streaming; status byte 4 | Manual — press remote while Scanning |
| T5 | **Remote drop** | Power off remote / leave range | ST_REMOTE_DROP; rem Recovering; synthetic button release if held; reconnect backoff | Code path present; manual verify on drop |
| T6 | **Queue overflow / motion drop** | Move mouse fast while notify is slow | Motion latest-only (no unbounded backlog); buttons preferred; metrics `tx_drop_*` / `ovf` rise under congestion | Host fault-inject + on-device metrics |
| T7 | **Button stuck prevention** | Hold key → disconnect Mac or remote | Mac: `releaseAllInputs`; ESP: `pending_rel` / flush | Pass on Mac; ESP path present |
| T8 | **Session / discovery stale** | Disconnect mid-discover | Stale callbacks `session_mismatch++`; do not mutate the new connection | Code path; HB metrics |

## Host CI (automated)

```bash
cd esp32-proxy-idf/tests/host && make test
```

Runs packet parse, decoder FD stub, bridge_state transitions, fault-inject flags.

## Manual checklist per RC

- [ ] T1 cold connect
- [ ] T3 reflash + Forget if needed
- [ ] T4 remote READY + air mouse + one key
- [ ] T2 app relaunch
- [ ] T5 remote drop → recover
