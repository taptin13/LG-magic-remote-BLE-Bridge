# MagicRemoteBLE — Release / signing

## Current status

- **Debug / local:** Automatic signing with Apple Development + team `7MHNHS24T2`.
- **Release:** Hardened Runtime enabled + Bluetooth entitlement. Suitable for Archive once a **Developer ID Application** certificate is installed.
- **Not yet:** Developer ID signing + notarization (no Developer ID cert on the current machine). Gatekeeper will still block unsigned / Development-signed downloads for end users.

## Checklist before wide distribution

1. Create **Developer ID Application** certificate in the Apple Developer account.
2. In Xcode → Signing & Capabilities (Release): identity **Developer ID Application**, team `7MHNHS24T2`.
3. Archive (`Product → Archive`), then **Distribute App → Developer ID → Upload** (notarize), or:
   ```bash
   xcodebuild archive -scheme MagicRemoteBLE -configuration Release \
     -archivePath build/MagicRemoteBLE.xcarchive
   xcodebuild -exportArchive -archivePath build/MagicRemoteBLE.xcarchive \
     -exportOptionsPlist ExportOptions-DeveloperID.plist \
     -exportPath build/export
   xcrun notarytool submit build/export/MagicRemoteBLE.app.zip \
     --keychain-profile "AC_NOTARY" --wait
   xcrun stapler staple build/export/MagicRemoteBLE.app
   ```
4. After signing, verify:
   - Bluetooth permission prompt / Privacy → Bluetooth
   - Accessibility for input injection
   - Pointer overlay still hides system cursor (private CGS path is best-effort; public fallback remains)

## Version source of truth

- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.pbxproj`
- `Info.plist` uses `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` — do not hardcode versions there

## Pointer overlay note

`SetsCursorInBackground` (private CGS) is loaded dynamically. If symbols are missing, the app falls back to `NSCursor.hide` + `CGDisplayHideCursor` only. Overlay arrow still works; system cursor may briefly reappear in some apps.
