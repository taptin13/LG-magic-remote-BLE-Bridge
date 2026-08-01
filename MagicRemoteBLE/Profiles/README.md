# Input device profiles

JSON profiles describe an LG Magic Remote (or similar) for the Mac app: button
codes, default key maps, mouse bindings, and the on-screen pad layout.

You can add another LG model **without changing Swift**.

## Where profiles live

| Location | Behavior |
|----------|----------|
| `MagicRemoteBLE/Profiles/*.json` in the app target | Shipped with the app |
| `~/Library/Application Support/MagicRemoteBLE/Profiles/*.json` | Loaded on launch; **same `id` overrides** the bundled file |

Restart the app after adding a drop-in file, then pick the profile in **Key Mapping**.

## Minimal workflow (new LG remote)

1. Copy `lg-mr25ga.json` → `lg-<model>.json`.
2. Set unique `id`, `displayName`, and `match.bleNameContains` (parts of the BLE name).
3. Connect with the stock ESP firmware (names containing `LGE MR` are accepted).
4. Press each key; note codes from the app log / last-button display.
5. Update `buttons`, `defaultMaps`, `mouseBindings`, and `pad`.
6. Select the profile in the UI and enable **Map** / **Mouse**.

Firmware note: ESP scans for `LGE MR25GA` or any name containing `LGE MR`. If your
remote uses a different advertisement name, change the matcher in
`esp32-proxy-idf/main/remote_manager.c` and reflash. See the root [README.md](../../README.md#adding-another-lg-remote).

## Schema

Required: `schemaVersion`, `id`, `displayName`, `buttons`, `defaultMaps`, `pad`.  
Optional: `match`, `mouseBindings`.

### `match`

```json
"match": {
  "bleNameContains": ["MR25GA", "LGE MR"]
}
```

Used to suggest / auto-pick a profile when a BLE name is known. Matching is
case-insensitive substring.

### `buttons`

```json
{ "code": "0x8044", "name": "Wheel/OK", "role": "ok" }
```

- `code` — `0xNNNN` from the bridge button packet  
- `name` — UI label  
- `role` — optional semantic id (`ok`, `back`, `settings`, …) for `mouseBindings`

### `mouseBindings`

```json
"mouseBindings": {
  "left": "ok",
  "right": "settings",
  "back": "back"
}
```

Values are `role` names from `buttons`. Used when **Mouse** mode is ON.

### `defaultMaps`

```json
{ "code": "0x8044", "mod": 0, "key": "0x28", "enabled": true }
```

- `mod` — modifier bitfield (same as the map table)  
- `key` — HID usage or special (`0xFE` Siri, `0xFD` mouse toggle, `0xF1`/`0xF2`/`0xF3` media)

### `pad`

Layout tree for `RemotePadView` (`sections` with `hstack` / `vstack` / `dpad` / items).
Copy from `lg-mr25ga.json` and adjust titles/codes for your remote’s face.

## Example: second model

```bash
cp MagicRemoteBLE/Profiles/lg-mr25ga.json \
   MagicRemoteBLE/Profiles/lg-mr18ga.json
# edit id, displayName, match, button codes…
```

Or drop-in without rebuilding:

```bash
mkdir -p ~/Library/Application\ Support/MagicRemoteBLE/Profiles
cp lg-mr18ga.json ~/Library/Application\ Support/MagicRemoteBLE/Profiles/
```

## Reference

- Bundled example: [`lg-mr25ga.json`](lg-mr25ga.json)  
- Protocol / MR25GA codes: [PROTOCOL.md](../../PROTOCOL.md)  
- Loader: `ProfileCatalog.swift`, `InputDeviceProfile.swift`
