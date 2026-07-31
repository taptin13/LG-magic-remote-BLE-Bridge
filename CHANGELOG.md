# Changelog

## v0.1.0-rc1 — 2026-07-31

Baseline đã flash + build/run Mac app trên máy dev (ESP32 + MagicRemoteBLE).

### Firmware (`esp32-proxy-idf`)
- BleCoreTask: sole owner GAP / GATTC / SM inject / Event notify
- Discovery: host callback enqueue `ble_disc_evt_t`; validate `conn` + `conn_gen` + `disc_gen`
- TX: motion latest-value, button/status queue, `s_tx_mu` bao mọi truy cập queue
- `s_pending_rel` — synthetic button release không mất khi overflow
- Mac ready = Event CCCD + encrypted; CMD `isfinite` validate
- Metrics + phase deadlines (scan/connect/security/discovery)
- `bridge_state` là source of truth cho remote link (không còn RM_* song song)

### Mac (`MagicRemoteBLE`)
- Auto scan→connect, prefs, mouse mode, adaptive smooth
- Disconnect: `releaseAllInputs`, discard pending motion

### Tooling
- GitHub Actions: PlatformIO firmware build + host unit tests; Xcode Debug build
- Host tests: protocol packet + decoder + bridge_state + fault-inject stubs
- Test matrix: `docs/TEST_MATRIX.md`
