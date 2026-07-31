import AppKit
import ApplicationServices
import Combine

/// Maps MR25GA HID 0xFD reports → Mac keyboard / mouse (CGEvent).
/// Airmouse algorithm mirrors lg-magic: LPF on gyro, dx∝gz, dy∝gx.
@MainActor
final class InputMapper: ObservableObject {
    @Published var enabled = false
    @Published var sensitivity: Double = 0.045
    @Published var airmouseThreshold: Double = 280
    @Published private(set) var pointerMode = false
    @Published private(set) var trusted = false
    @Published private(set) var status = "off"

    var onLog: ((LogLevel, String) -> Void)?

    private var lastButton: UInt16 = 0
    private var heldKey: CGKeyCode?
    private var mouseDown = false
    private var gyroLPF: (Double, Double, Double) = (0, 0, 0)
    private var gyroBias: (Double, Double, Double) = (0, 0, 0)
    private var biasSum: (Double, Double, Double) = (0, 0, 0)
    private var biasSamples = 0
    private var calibratingBias = false
    private var pixelCarry = CGPoint.zero
    private let biasWarmup = 60
    private let lpfAlpha = 0.42          // phản hồi nhanh hơn (trước 0.28 → ì)
    private let softDead = 28.0          // soft knee, không cắt cứng
    private let stillGate = 70.0
    private let wheelOK: UInt16 = 0x8044

    /// Remote consumer code → Mac virtual key (when not acting as mouse click).
    private static let keyMap: [UInt16: CGKeyCode] = [
        0x8040: 126, // Up
        0x8041: 125, // Down
        0x8006: 124, // Right
        0x8007: 123, // Left
        0x8044: 36,  // Wheel/OK → Return
        0x8028: 53,  // Back → Escape
        0x807C: 4,   // Home → H (with ⌘)
        0x8045: 49,  // Menu → Space
        0x8043: 43,  // Settings → , (with ⌘)
        0x8010: 29, 0x8011: 18, 0x8012: 19, 0x8013: 20, 0x8014: 21,
        0x8015: 23, 0x8016: 22, 0x8017: 26, 0x8018: 28, 0x8019: 25,
        0x80B0: 49,  // Play → Space
    ]

    private static let mediaMap: [UInt16: Int32] = [
        0x8002: NX_KEYTYPE_SOUND_UP,
        0x8003: NX_KEYTYPE_SOUND_DOWN,
        0x8009: NX_KEYTYPE_MUTE,
        0x80BA: NX_KEYTYPE_PLAY,
    ]

    func refreshTrust() {
        trusted = AXIsProcessTrusted()
        if enabled && !trusted {
            status = "cần Accessibility"
        }
    }

    func setEnabled(_ on: Bool) {
        if on {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
            guard trusted else {
                enabled = false
                status = "cần Accessibility"
                onLog?(.error, "Bật Accessibility cho MagicRemoteStudio (System Settings → Privacy)")
                return
            }
            enabled = true
            startBiasCalibration()
            onLog?(.matrix, "Input mapping ON — giữ yên remote ~1s để calib bias, rồi rê = chuột")
        } else {
            releaseAll()
            enabled = false
            pointerMode = false
            calibratingBias = false
            status = "off"
            onLog?(.info, "Input mapping OFF")
        }
    }

    func recalibrateBias() {
        guard enabled else { return }
        startBiasCalibration()
        onLog?(.info, "Recalibrating gyro bias — giữ yên remote")
    }

    private func startBiasCalibration() {
        calibratingBias = true
        biasSamples = 0
        biasSum = (0, 0, 0)
        gyroLPF = (0, 0, 0)
        pixelCarry = .zero
        pointerMode = false
        status = "calib bias…"
    }

    func handle(_ report: HIDFDReport) {
        guard enabled, trusted else { return }

        if report.imu.count >= 3 {
            let gx = Double(report.imu[0])
            let gy = Double(report.imu[1])
            let gz = Double(report.imu[2])

            if calibratingBias {
                biasSum.0 += gx
                biasSum.1 += gy
                biasSum.2 += gz
                biasSamples += 1
                if biasSamples >= biasWarmup {
                    let n = Double(biasSamples)
                    gyroBias = (biasSum.0 / n, biasSum.1 / n, biasSum.2 / n)
                    calibratingBias = false
                    gyroLPF = (0, 0, 0)
                    pixelCarry = .zero
                    status = "mapping"
                    onLog?(.info, String(format: "Gyro bias gx=%.0f gy=%.0f gz=%.0f", gyroBias.0, gyroBias.1, gyroBias.2))
                }
            } else {
                var cx = gx - gyroBias.0
                var cy = gy - gyroBias.1
                var cz = gz - gyroBias.2

                if abs(cx) < stillGate && abs(cz) < stillGate {
                    let b = 0.0015
                    gyroBias.0 = (1 - b) * gyroBias.0 + b * gx
                    gyroBias.1 = (1 - b) * gyroBias.1 + b * gy
                    gyroBias.2 = (1 - b) * gyroBias.2 + b * gz
                    cx = gx - gyroBias.0
                    cy = gy - gyroBias.1
                    cz = gz - gyroBias.2
                }

                let a = lpfAlpha
                gyroLPF.0 = a * cx + (1 - a) * gyroLPF.0
                gyroLPF.1 = a * cy + (1 - a) * gyroLPF.1
                gyroLPF.2 = a * cz + (1 - a) * gyroLPF.2

                let sx = softAxis(gyroLPF.2)
                let sy = softAxis(gyroLPF.0)
                let mag = max(abs(gyroLPF.0), abs(gyroLPF.2))
                if mag > airmouseThreshold { pointerMode = true }

                // Luôn integrate khi có chuyển động (không chờ pointerMode) — mượt hơn
                if sx != 0 || sy != 0 {
                    moveMouseRelative(dx: sx * sensitivity, dy: sy * sensitivity)
                }
            }
        }

        // --- Wheel ---
        if report.wheel != 0 {
            if pointerMode {
                scroll(deltaY: Int32(report.wheel))
            } else {
                tapKey(report.wheel > 0 ? 126 : 125)
            }
        }

        // --- Buttons (edge) ---
        let code = report.buttonCode
        guard code != lastButton else { return }
        let previous = lastButton
        lastButton = code

        if previous != 0 {
            releaseButton(previous)
        }
        if code != 0 {
            pressButton(code)
        }
    }

    private func pressButton(_ code: UInt16) {
        if code == wheelOK && pointerMode {
            mouseClick(down: true)
            mouseDown = true
            return
        }
        if let media = Self.mediaMap[code] {
            postMedia(media, down: true)
            return
        }
        if code == 0x807C { // Home → ⌘H
            key(4, down: true, flags: .maskCommand)
            heldKey = 4
            return
        }
        if code == 0x8043 { // Settings → ⌘,
            key(43, down: true, flags: .maskCommand)
            heldKey = 43
            return
        }
        if let vk = Self.keyMap[code] {
            key(vk, down: true)
            heldKey = vk
        }
    }

    private func releaseButton(_ code: UInt16) {
        if code == wheelOK && mouseDown {
            mouseClick(down: false)
            mouseDown = false
            return
        }
        if let media = Self.mediaMap[code] {
            postMedia(media, down: false)
            return
        }
        if let vk = heldKey {
            let flags: CGEventFlags = (code == 0x807C || code == 0x8043) ? .maskCommand : []
            key(vk, down: false, flags: flags)
            heldKey = nil
        }
    }

    private func releaseAll() {
        if mouseDown { mouseClick(down: false); mouseDown = false }
        if let vk = heldKey { key(vk, down: false); heldKey = nil }
        lastButton = 0
        gyroLPF = (0, 0, 0)
        pixelCarry = .zero
        calibratingBias = false
    }

    /// Soft deadzone + nhẹ gain khi nhanh (tránh giật on/off).
    private func softAxis(_ v: Double) -> Double {
        let a = abs(v)
        if a <= softDead { return 0 }
        let excess = a - softDead
        // curve: mượt gần deadzone, nhanh hơn khi vung mạnh
        let shaped = excess + excess * excess * 0.0008
        return v < 0 ? -shaped : shaped
    }

    private func moveMouseRelative(dx: Double, dy: Double) {
        pixelCarry.x += dx
        pixelCarry.y += dy
        let ix = pixelCarry.x.rounded(.towardZero)
        let iy = pixelCarry.y.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        pixelCarry.x -= ix
        pixelCarry.y -= iy

        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main else { return }
        let h = screen.frame.maxY
        var x = loc.x + ix
        var yTop = (h - loc.y) + iy
        let f = screen.frame
        x = min(max(x, f.minX), f.maxX - 1)
        yTop = min(max(yTop, h - f.maxY), h - f.minY - 1)
        let pos = CGPoint(x: x, y: yTop)
        let type: CGEventType = mouseDown ? .leftMouseDragged : .mouseMoved
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        ev.post(tap: .cghidEventTap)
    }

    private func moveMouse(dx: Double, dy: Double) {
        moveMouseRelative(dx: dx, dy: dy)
    }

    private func mouseClick(down: Bool) {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return }
        let pos = CGPoint(x: loc.x, y: screen.frame.maxY - loc.y)
        let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: .left)
        ev?.post(tap: .cghidEventTap)
    }

    private func scroll(deltaY: Int32) {
        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        ev?.flags = flags
        ev?.post(tap: .cghidEventTap)
    }

    private func tapKey(_ code: CGKeyCode) {
        key(code, down: true)
        key(code, down: false)
    }

    private func postMedia(_ key: Int32, down: Bool) {
        let keyCode = Int64(key)
        let keyState = down ? Int64(0xa) : Int64(0xb)
        let data1 = (keyCode << 16) | (keyState << 8)
        guard let ev = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(data1),
            data2: -1
        )?.cgEvent else { return }
        ev.post(tap: .cghidEventTap)
    }
}

// IOKit media key constants (same as Carbon/NX)
private let NX_KEYTYPE_SOUND_UP: Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_MUTE: Int32 = 7
private let NX_KEYTYPE_PLAY: Int32 = 16
