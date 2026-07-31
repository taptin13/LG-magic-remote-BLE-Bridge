# Test matrix (thực tế)

Môi trường baseline: ESP32-D0WD-V3 + macOS + MagicRemoteBLE + remote `LGE MR25GA`.

| ID | Kịch bản | Bước | Kỳ vọng | Kết quả baseline |
|----|----------|------|---------|------------------|
| T1 | **Cold boot → Mac connect** | Flash/reset ESP → mở app → Connect MR-Proxy | Serial: ADV → Connected → Encrypted → MacReady; overall WaitingForRemote; app bond OK | Pass (2026-07-31) |
| T2 | **Reconnect Mac** | Disconnect app / kill app → mở lại Connect | ESP giữ bond; MacReady lại; remote không bắt buộc pair lại nếu vẫn up | Pass (auto reconnect sau reflash) |
| T3 | **Reflash / bond mismatch** | `pio run -t upload` → app Connect | Nếu `Peer removed pairing`: Forget MR-Proxy rồi Connect; CMD sens sau ENC | Pass (cần Forget khi bond lệch) |
| T4 | **Remote scan / reconnect** | MacReady + bấm nút remote | SCAN → CONNECT → ENC → Discover → READY / Streaming; status byte 4 | Manual — cần bấm remote khi Scanning |
| T5 | **Remote drop** | Tắt pin remote / ra ngoài range | ST_REMOTE_DROP; rem Recovering; synthetic button release nếu đang giữ; reconnect backoff | Code path có; verify tay khi drop |
| T6 | **Queue overflow / motion drop** | Rê chuột nhanh khi notify chậm | Motion latest-only (không backlog vô hạn); button ưu tiên; metrics `tx_drop_*` / `ovf` tăng nếu nghẽn | Fault-inject host + metrics trên device |
| T7 | **Button stuck prevention** | Giữ phím → disconnect Mac hoặc remote | Mac: `releaseAllInputs`; ESP: `pending_rel` / flush | Pass phía Mac; ESP path đã có |
| T8 | **Session / discovery stale** | Disconnect giữa discover | Callback cũ `session_mismatch++`; không sửa state connection mới | Code path; metrics HB |

## Host CI (tự động)

```bash
cd esp32-proxy-idf/tests/host && make test
```

Chạy packet parse, decoder FD stub, bridge_state transitions, fault-inject flags.

## Manual checklist mỗi RC

- [ ] T1 cold connect
- [ ] T3 reflash + Forget nếu cần
- [ ] T4 remote READY + airmouse + 1 phím
- [ ] T2 app relaunch
- [ ] T5 remote drop → recover
