# MagicRemote Studio v0.1

A clean macOS SwiftUI/CoreBluetooth prototype for studying LG Magic Remote MR25GA and other proprietary BLE devices.

## Current blocker

A fixed 95-write sweep (19 candidates × 5 writable targets) completed with
**zero notifications back**. The remote still closes the link at ~2.3s. Guessing
echo/short payloads on `A001`/`A002`/`FFD1`/`FFD8`/`FFF2` is exhausted.

One new GATT clue: `FFF2` rejects some lengths with ATT “value's length is
invalid”, so it expects a fixed schema. Next useful step is reading `FFF1`
(and the other D0FF reads) inside the watchdog window, then writing only legal
`FFF2` lengths.

See [FINDINGS.md](FINDINGS.md).

## How it works

One button. Pressing **Run**:

1. Sequentially reads `FFF1`, then `FFD2`–`FFD5`, `FFE0`–`FFE2` (across
   connections if the watchdog cuts mid-probe)
2. Builds 12-byte `FFF2` candidates from `FFF1` (length-prefixed record)
3. Writes them one-at-a-time, waiting for ACK/NAK
4. Stops on the first `A001` notification

All parameters live in `SweepConfig`.

Also included:

- Remaining watchdog budget printed on every connect, measured from link
  establishment rather than from the connect request
- RX/TX packet recorder and JSON Lines export
- Linux `brainrom/lg-magic` compatible `0xFD` decoder

## Important behavior

The app never reconnects on its own outside a sweep, which avoids repeated macOS
“connected” notifications. A sweep owns its reconnect cycle and can be stopped at
any time.

## Build

1. Open `MagicRemoteStudio.xcodeproj` in Xcode on macOS.
2. Select the `MagicRemoteStudio` scheme.
3. Set a development team only if your local Xcode requires signing.
4. Run the app and approve Bluetooth access.

The project was generated in a Linux environment where Xcode is unavailable, so the `.xcodeproj` could not be compiled here. The source is structured for macOS 13+ and Swift 5.

## Decoder provenance

The `0xFD` layout follows the uploaded `brainrom/lg-magic` Linux driver:

- exactly 20 bytes
- byte 0: `0xFD`
- bytes 1–2: little-endian counter
- bytes 5–16: six signed big-endian Int16 IMU values
- bytes 17–18: big-endian button code
- byte 19: signed wheel value

No claim is made that raw `A001` notifications contain this report directly. The analyzer searches for it at every possible offset.

## Included reference source

`lg-magic-master/` is a Linux Bluetooth-HID driver/tools reference. It parses
reports after the operating system has already exposed the remote as HID; it
does not implement the proprietary BLE GATT handshake used by MR25GA. Its
`0xFD` parser requires the little-endian `0xFD00` marker at bytes 3–4, which is
also enforced by MagicRemote Studio.

Because it only sees traffic after a successful bond, it offers no help with the
pairing problem described above.
