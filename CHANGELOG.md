# Changelog

## v0.1.5 — 2026-08-04

### Mac (`MagicRemoteBLE`)
- Parse a backward-compatible firmware protocol handshake with version and capabilities.
- Invalidate stale delayed reconnect callbacks after sleep, radio reset, or manual reconnect.

### Firmware (`esp32-proxy-idf`)
- Move remote notification decode out of the NimBLE GAP callback into a bounded RX queue.
- Reject stale RX packets using the remote session generation.
- Add RX overflow metrics and remove investigation-only voice/vendor logging from the production path.

### Validation
- Hardware test pass: mouse, buttons, scroll, battery, sleep/wake, reconnect, and bond recovery.
- XCTest, ESP32 host tests, and PlatformIO firmware build pass.

## v0.1.4 — 2026-08-04

### Mac (`MagicRemoteBLE`)
- Recover cleanly when CoreBluetooth resets the radio after system sleep.
- Wait for the Bluetooth controller to settle before reconnecting.
- Prefer the cached peripheral UUID before falling back to a new scan.
- Retry transient pairing-state errors once before asking the user to forget `MR-Proxy`.
- Keep XCTest isolated from WindowServer cursor APIs on CI runners.

### Firmware (`esp32-proxy-idf`)
- Reduce idle `BleCoreTask` wakeups from 2 ms to 10 ms.
- Make the Mac bridge event-driven instead of polling every 20 ms when idle.
- Preserve motion/button event wakeup behavior and protocol compatibility.

### Validation
- macOS Universal Debug/Release builds pass.
- XCTest, ESP32 PlatformIO build, and ESP32 host tests pass.
- Artifact remains ad-hoc signed; Developer ID signing/notarization is required for broad distribution.

## v0.1.3 — 2026-08-03

### Mac (`MagicRemoteBLE`)
- Rebind the remote BLE session automatically after macOS wake and reconnect.
- Read the standard Battery Service (`0x180F` / `0x2A19`) and show the remote battery in the app and menu dropdown.
- Keep the menu bar icon compact without placing the battery percentage beside it.
- Stop reconnect retry loops on macOS pairing-information mismatch and show recovery guidance.
- Fix Swift concurrency capture issues for Xcode and CI builds.
- Version SoT: Info.plist uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` (0.1.3 / 3)

## v0.1.2 — 2026-08-02

### Mac (`MagicRemoteBLE`)
- Recover stale CoreBluetooth sessions after macOS system wake and retry
  connection after the Bluetooth radio settles
- Coalesce BLE keepalive traffic when event notifications are active
- Replace the permanent smoothing timer with demand-driven scheduling
- Allow system idle sleep and make performance diagnostics opt in
- Add an optimized Universal Release build script with Bluetooth entitlement
- Session/peripheral guards on all CoreBluetooth callbacks (`connectionGeneration` + active ID)
- Auto-reconnect exponential backoff: 1s → 2s → 5s → 10s → 30s (reset on `.ready`)
- `InputPacketSink` replaces bare `nonisolated(unsafe)` input callback
- Pointer overlay: probe private CGS; fallback to `NSCursor.hide` + `CGDisplayHideCursor`
- Version SoT: Info.plist uses `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` (0.1.2 / 3)
- Signing: Automatic + team `7MHNHS24T2`, Hardened Runtime, Bluetooth entitlements
- XCTest target `MagicRemoteBLETests` (packet parse + input sink)
- Docs: `docs/RELEASE.md` (Developer ID + notarization still required for wide distribution)

## v0.1.0-rc1 — 2026-07-31

Baseline flashed and Mac app built/run on the development machine (ESP32 + MagicRemoteBLE).

### Firmware (`esp32-proxy-idf`)
- BleCoreTask: sole owner of GAP / GATTC / SM inject / Event notify
- Discovery: host callbacks enqueue `ble_disc_evt_t`; validate `conn` + `conn_gen` + `disc_gen`
- TX: motion latest-value, button/status queue, `s_tx_mu` covers all queue access
- `s_pending_rel` — synthetic button release not lost on overflow
- Mac ready = Event CCCD + encrypted; CMD `isfinite` validation
- Metrics + phase deadlines (scan/connect/security/discovery)
- `bridge_state` is the source of truth for the remote link (no parallel `RM_*`)

### Mac (`MagicRemoteBLE`)
- Auto scan→connect, prefs, mouse mode, adaptive smooth
- Disconnect: `releaseAllInputs`, discard pending motion

### Tooling
- GitHub Actions: PlatformIO firmware build + host unit tests; Xcode Debug build
- Host tests: protocol packet + decoder + bridge_state + fault-inject stubs
- Test matrix: `docs/TEST_MATRIX.md`

## Unreleased

Further production hardening and wider-device validation are tracked here.
