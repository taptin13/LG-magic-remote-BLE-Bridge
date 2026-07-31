import AppKit
import ApplicationServices
import Combine

/// Nhận BridgePacket → CGEvent theo `keyMaps`.
/// Motion chạy lock — không bắt buộc MainActor (mượt hơn khi BLE notify dồn).
final class InputMapper: ObservableObject {
    @Published var enabled = false
    @Published private(set) var trusted = false
    @Published private(set) var status = "off"
    /// Chuột bay: OK=L, Settings=R, Back=Mouse Back; motion chỉ khi bật.
    @Published private(set) var mouseMode = false

    var onLog: ((LogLevel, String) -> Void)?
    /// Lookup map hiện tại (AppModel cung cấp) — chỉ dùng khi chưa có cache.
    var resolveMap: ((UInt16) -> KeyMapRow?)?
    /// Báo AppModel hiện Magic pointer (chỉ khi remote điều khiển).
    var onRemotePointerActivity: (() -> Void)?

    private let lock = NSLock()
    private var heldKey: CGKeyCode?
    private var heldFlags: CGEventFlags = []
    private var mouseButtons: UInt16 = 0
    private var enabledFlag = false
    private var trustedFlag = false
    private var smoothingFlag = true
    private var nativeScrollFlag = true
    private var mouseModeFlag = false
    /// Cache map — tránh resolveMap hop MainActor từ BLE queue (deadlock).
    private var mapCache: [UInt16: KeyMapRow] = [:]

    private static let btnBack: UInt16 = 0x8028
    private static let btnSettings: UInt16 = 0x8043
    private static let btnOK: UInt16 = 0x8044

    /// Click / scroll / phím: remote khó giữ yên → đóng băng motion tạm thời.
    /// hardLock = không được phá (chống cộng dồn rung tay). softFreeze = phá nếu rê mạnh một phát.
    private var dragArmed = false
    private var dragAccum: Double = 0
    private var clickSettleUntil: CFAbsoluteTime = 0
    private var hardLockUntil: CFAbsoluteTime = 0
    private var softFreezeUntil: CFAbsoluteTime = 0
    private var postGateUntil: CFAbsoluteTime = 0
    private var coherentBreakAccum: Double = 0
    private var lastBreakDX = 0.0
    private var lastBreakDY = 0.0
    private var lastClickUpAt: CFAbsoluteTime = 0

    /// Đếm click cho CGEvent (HID không tự gán clickState → app không nhận double-click).
    private var mouseClickCount: Int64 = 0
    private var lastMouseDownUptime: TimeInterval = 0
    private var lastMouseDownQuartz = CGPoint.zero
    private var lastMouseDownButton: CGMouseButton?

    private static let dragThreshold: Double = 40
    private static let clickSettleSec: CFTimeInterval = 0.14
    private static let clickHardSec: CFTimeInterval = 0.15
    private static let clickSoftSec: CFTimeInterval = 0.08
    private static let releaseHardSec: CFTimeInterval = 0.18
    private static let scrollHardSec: CFTimeInterval = 0.20
    private static let keyHardSec: CFTimeInterval = 0.16
    private static let keySoftSec: CFTimeInterval = 0.08
    private static let postGateSec: CFTimeInterval = 0.10
    /// Cửa sổ double-click hệ thống — giữ pointer chết trong khoảng này.
    private static let doubleClickWindow: CFTimeInterval = 0.55
    /// Một gói motion lớn mới được coi là rê chủ ý (không cộng dồn rung).
    private static let instantBreakMag: Double = 18
    /// Chuỗi motion cùng hướng sau hard-lock.
    private static let coherentBreakThreshold: Double = 55
    private static let motionGateEpsilon: Double = 0.8

    /// Display-paced smoothing: gói BLE giật → chia nhỏ theo ~125Hz.
    private var pendingDX = 0.0
    private var pendingDY = 0.0
    /// nil = mouseMoved; left/right/center = đúng loại *Dragged.
    private var pendingDragButton: CGMouseButton?
    private var smoothTimer: DispatchSourceTimer?
    private var lastSmoothAt: CFAbsoluteTime = 0
    private var lastPointerActivityAt: CFAbsoluteTime = 0
    private let smoothQueue = DispatchQueue(label: "mr.mouse.smooth", qos: .userInteractive)

    /// Adaptive tau theo tốc độ residual (nhỏ → mượt; nhanh → ít trễ).
    private static let pendingMotionCap: Double = 64
    private static let pointerActivityMinInterval: CFTimeInterval = 1.0 / 45.0

    private static func smoothTau(forSpeed speed: Double) -> CFTimeInterval {
        if speed < 3 { return 0.014 }
        if speed < 12 { return 0.008 }
        return 0.004
    }

    /// HID usage → macOS virtual key.
    private static let hidToVK: [UInt8: CGKeyCode] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x0B: 4, 0x14: 12, 0x19: 9, 0x1A: 13,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23,
        0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x36: 43,
        0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
    ]

    private static let mediaHID: [UInt8: Int32] = [
        0xF1: 0, 0xF2: 1, 0xF3: 7,
    ]

    @MainActor
    func refreshTrust() {
        trusted = AXIsProcessTrusted()
        trustedFlag = trusted
        if enabled && !trusted { status = "cần Accessibility" }
    }

    @MainActor
    func setEnabled(_ on: Bool) {
        if on {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
            trustedFlag = trusted
            guard trusted else {
                enabled = false
                enabledFlag = false
                status = "cần Accessibility"
                onLog?(.error, "Bật Accessibility cho MagicRemoteBLE")
                return
            }
            enabled = true
            enabledFlag = true
            status = "mapping"
            ensureSmoothTimer()
            onLog?(.matrix, "Input ON — map theo Config")
        } else {
            releaseAllInputs()
            stopSmoothTimer()
            enabled = false
            enabledFlag = false
            status = "off"
        }
    }

    func setMotionSmoothing(_ on: Bool) {
        smoothingFlag = on
        if on { ensureSmoothTimer() } else {
            flushPendingMotion()
        }
    }

    func setNativeScroll(_ on: Bool) {
        nativeScrollFlag = on
    }

    /// Gọi từ MainActor khi keyMaps đổi.
    func updateMaps(_ rows: [KeyMapRow]) {
        var next: [UInt16: KeyMapRow] = [:]
        next.reserveCapacity(rows.count)
        for r in rows { next[r.buttonCode] = r }
        lock.lock()
        mapCache = next
        lock.unlock()
    }

    func setMouseMode(_ on: Bool) {
        lock.lock()
        mouseModeFlag = on
        if !on {
            pendingDX = 0
            pendingDY = 0
            pendingDragButton = nil
        }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.mouseMode = on
        }
        logAsync(.ok, on ? "Mouse mode ON — OK=L · Settings=R · Back=MouseBack" : "Mouse mode OFF — phím theo map")
    }

    private func logAsync(_ level: LogLevel, _ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(level, msg)
        }
    }

    private func mappedRow(for code: UInt16) -> KeyMapRow? {
        lock.lock()
        let row = mapCache[code]
        lock.unlock()
        return row
    }

    /// Gọi từ BLE queue (không MainActor) — path chuột ưu tiên.
    func handle(_ packet: BridgePacket) {
        guard enabledFlag, trustedFlag else { return }
        switch packet.type {
        case .motion:
            applyMouse(dx: Int(packet.dx), dy: Int(packet.dy), wheel: Int(packet.wheel))
        case .button:
            applyButton(code: packet.buttonCode, down: packet.buttonDown)
        case .voice:
            if packet.buttonDown { activateSiri() }
        default:
            break
        }
    }

    private func applyMouse(dx: Int, dy: Int, wheel: Int) {
        lock.lock()
        let mouseOn = mouseModeFlag
        let dragBtn = Self.dragButton(from: mouseButtons)
        lock.unlock()

        if wheel != 0 {
            freezeMotion(hard: Self.scrollHardSec, soft: 0, postGate: false)
            scroll(deltaY: Int32(wheel))
        }

        /* Chuột bay tắt → nuốt dx/dy. */
        guard mouseOn, dx != 0 || dy != 0 else { return }

        let holding = dragBtn != nil
        if holding && !allowDragMotion(dx: Double(dx), dy: Double(dy)) {
            discardPendingMotion()
            return
        }
        guard let gated = gatedMotion(dx: Double(dx), dy: Double(dy)) else {
            return
        }

        if smoothingFlag {
            lock.lock()
            pendingDX = Self.clampPending(pendingDX + gated.dx)
            pendingDY = Self.clampPending(pendingDY + gated.dy)
            pendingDragButton = dragBtn
            lock.unlock()
            ensureSmoothTimer()
        } else {
            moveMouse(dx: gated.dx, dy: gated.dy, dragButton: dragBtn)
        }
    }

    /// Ưu tiên L → R → Middle khi giữ nhiều nút.
    private static func dragButton(from mask: UInt16) -> CGMouseButton? {
        if (mask & 1) != 0 { return .left }
        if (mask & 2) != 0 { return .right }
        if (mask & 4) != 0 { return .center }
        return nil
    }

    private static func clampPending(_ v: Double) -> Double {
        min(pendingMotionCap, max(-pendingMotionCap, v))
    }

    private func handleClickEdge(button: CGMouseButton, down: Bool, alsoEndHoldIfUp: Bool = true) {
        mouseClick(button: button, down: down)
        if down {
            beginClickHold()
            if inDoubleClickWindow() {
                freezeMotion(hard: max(Self.clickHardSec, NSEvent.doubleClickInterval), soft: 0, postGate: false)
            } else {
                freezeMotion(hard: Self.clickHardSec, soft: Self.clickSoftSec)
            }
        } else {
            if alsoEndHoldIfUp { endClickHold() }
            markClickUp()
            freezeMotion(hard: Self.releaseHardSec, soft: 0, postGate: false)
        }
    }

    /// Mouse mode: OK=L, Settings=R, Back=Mouse Back. Ngược lại: map bình thường (+ Siri / Mouse toggle).
    private func applyButton(code: UInt16, down: Bool) {
        lock.lock()
        let mouseOn = mouseModeFlag
        lock.unlock()

        if mouseOn {
            switch code {
            case Self.btnOK:
                setSyntheticMouseBit(1, down: down)
                lock.lock()
                let otherHeld = (mouseButtons & 0b110) != 0
                lock.unlock()
                handleClickEdge(button: .left, down: down, alsoEndHoldIfUp: !otherHeld)
                return
            case Self.btnSettings:
                setSyntheticMouseBit(2, down: down)
                lock.lock()
                let otherHeld = (mouseButtons & 0b101) != 0
                lock.unlock()
                handleClickEdge(button: .right, down: down, alsoEndHoldIfUp: !otherHeld)
                return
            case Self.btnBack:
                setSyntheticMouseBit(8, down: down)
                mouseBack(down: down)
                freezeMotion(
                    hard: down ? Self.clickHardSec : Self.releaseHardSec,
                    soft: down ? Self.clickSoftSec : 0,
                    postGate: false
                )
                return
            default:
                break
            }
        }

        guard let row = mappedRow(for: code), row.enabled, row.key != 0 else { return }

        if row.key == HIDKeyPresets.siriKey {
            if down { activateSiri() }
            return
        }
        if row.key == HIDKeyPresets.mouseToggleKey {
            guard down else { return }
            lock.lock()
            let next = !mouseModeFlag
            mouseModeFlag = next
            let mb = mouseButtons
            mouseButtons = 0
            pendingDX = 0
            pendingDY = 0
            pendingDragButton = nil
            lock.unlock()
            if (mb & 1) != 0 { mouseClick(button: .left, down: false) }
            if (mb & 2) != 0 { mouseClick(button: .right, down: false) }
            if (mb & 4) != 0 { mouseClick(button: .center, down: false) }
            if (mb & 8) != 0 { mouseBack(down: false) }
            if !next { discardPendingMotion() }
            /* Chỉ async lên main — không sync MainActor từ BLE (tránh treo). */
            DispatchQueue.main.async { [weak self] in
                self?.mouseMode = next
            }
            logAsync(.ok, next ? "Mouse mode ON — OK=L · Settings=R · Back=MouseBack" : "Mouse mode OFF")
            return
        }

        freezeMotion(hard: Self.keyHardSec, soft: Self.keySoftSec)

        if let media = Self.mediaHID[row.key] {
            if down {
                postMedia(media, down: true)
                postMedia(media, down: false)
            }
            return
        }

        guard let vk = Self.hidToVK[row.key] else { return }
        var flags: CGEventFlags = []
        if (row.mod & 0x01) != 0 { flags.insert(.maskControl) }
        if (row.mod & 0x02) != 0 { flags.insert(.maskShift) }
        if (row.mod & 0x04) != 0 { flags.insert(.maskAlternate) }
        if (row.mod & 0x08) != 0 { flags.insert(.maskCommand) }

        key(vk, down: down, flags: flags)
        lock.lock()
        if down {
            heldKey = vk
            heldFlags = flags
        } else if heldKey == vk {
            heldKey = nil
            heldFlags = []
        }
        lock.unlock()
    }

    private func setSyntheticMouseBit(_ bit: UInt16, down: Bool) {
        lock.lock()
        if down { mouseButtons |= bit } else { mouseButtons &= ~bit }
        lock.unlock()
    }

    private func ensureSmoothTimer() {
        guard smoothingFlag, smoothTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: smoothQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.smoothTick() }
        t.resume()
        smoothTimer = t
    }

    private func stopSmoothTimer() {
        smoothTimer?.cancel()
        smoothTimer = nil
        lock.lock()
        pendingDX = 0
        pendingDY = 0
        pendingDragButton = nil
        lastSmoothAt = 0
        lock.unlock()
    }

    private func flushPendingMotion() {
        lock.lock()
        let dx = pendingDX, dy = pendingDY, drag = pendingDragButton
        pendingDX = 0
        pendingDY = 0
        pendingDragButton = nil
        lock.unlock()
        if dx != 0 || dy != 0 { moveMouse(dx: dx, dy: dy, dragButton: drag) }
    }

    private func discardPendingMotion() {
        lock.lock()
        pendingDX = 0
        pendingDY = 0
        pendingDragButton = nil
        lock.unlock()
    }

    private func smoothTick() {
        guard enabledFlag else { return }
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now < hardLockUntil || now < softFreezeUntil {
            pendingDX = 0
            pendingDY = 0
            lock.unlock()
            return
        }
        var dx = pendingDX
        var dy = pendingDY
        let drag = pendingDragButton
        if dx == 0 && dy == 0 {
            lastSmoothAt = now
            lock.unlock()
            return
        }
        let dt: CFTimeInterval
        if lastSmoothAt > 0 {
            dt = min(0.05, max(0.001, now - lastSmoothAt))
        } else {
            dt = 0.008
        }
        lastSmoothAt = now
        let speed = hypot(dx, dy)
        let tau = Self.smoothTau(forSpeed: speed)
        let gain = 1.0 - exp(-dt / tau)
        let stepX: Double
        let stepY: Double
        if abs(dx) < 0.85 && abs(dy) < 0.85 {
            stepX = dx
            stepY = dy
            pendingDX = 0
            pendingDY = 0
        } else {
            stepX = dx * gain
            stepY = dy * gain
            pendingDX -= stepX
            pendingDY -= stepY
        }
        let gateUntil = postGateUntil
        lock.unlock()

        var outX = stepX, outY = stepY
        if now < gateUntil {
            let t = max(0, (gateUntil - now) / Self.postGateSec)
            let gateGain = 1.0 - 0.75 * t
            outX *= gateGain
            outY *= gateGain
        }
        if outX != 0 || outY != 0 {
            moveMouse(dx: outX, dy: outY, dragButton: drag)
        }
    }
    private func scroll(deltaY: Int32) {
        guard deltaY != 0 else { return }
        /* Native (macOS) = đảo chiều (Natural Scrolling). Tắt = hướng Windows. */
        let dy = nativeScrollFlag ? -deltaY : deltaY
        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: dy,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        ev.post(tap: .cghidEventTap)
    }

    /// hard: tuyệt đối không rê. soft: chỉ phá nếu rê mạnh/cùng hướng (không cộng rung).
    private func freezeMotion(hard: CFTimeInterval, soft: CFTimeInterval, postGate: Bool = true) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let hardUntil = now + hard
        let softUntil = hardUntil + soft
        if hardUntil > hardLockUntil { hardLockUntil = hardUntil }
        if softUntil > softFreezeUntil { softFreezeUntil = softUntil }
        if postGate {
            postGateUntil = softUntil + Self.postGateSec
        } else {
            /* Giữ yên hết soft — phục vụ double-click / scroll. */
            postGateUntil = 0
        }
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        pendingDX = 0
        pendingDY = 0
        lock.unlock()
    }

    private func inDoubleClickWindow() -> Bool {
        lock.lock()
        let t = lastClickUpAt
        lock.unlock()
        guard t > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - t < Self.doubleClickWindow
    }

    private func markClickUp() {
        lock.lock()
        lastClickUpAt = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// `nil` = nuốt; có giá trị = motion đã nhân gain post-gate.
    private func gatedMotion(dx: Double, dy: Double) -> (dx: Double, dy: Double)? {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let mag = hypot(dx, dy)

        if now < hardLockUntil {
            pendingDX = 0
            pendingDY = 0
            coherentBreakAccum = 0
            return nil
        }

        if now < softFreezeUntil {
            /* Phá sớm chỉ khi: (1) một phát đủ lớn, hoặc (2) chuỗi cùng hướng. */
            if mag >= Self.instantBreakMag {
                clearFreezeLocked(now: now)
            } else {
                let dot = dx * lastBreakDX + dy * lastBreakDY
                let sameDir = (lastBreakDX == 0 && lastBreakDY == 0) || dot > 0
                if sameDir && mag >= Self.motionGateEpsilon {
                    coherentBreakAccum += mag
                    lastBreakDX = dx
                    lastBreakDY = dy
                } else {
                    coherentBreakAccum *= 0.35
                    lastBreakDX = dx
                    lastBreakDY = dy
                }
                if coherentBreakAccum < Self.coherentBreakThreshold {
                    pendingDX = 0
                    pendingDY = 0
                    return nil
                }
                clearFreezeLocked(now: now)
            }
        } else {
            coherentBreakAccum = 0
            if mag < Self.motionGateEpsilon { return nil }
        }

        var outDX = dx, outDY = dy
        if now < postGateUntil {
            let t = max(0, (postGateUntil - now) / Self.postGateSec)
            let gain = 1.0 - 0.85 * t
            outDX *= gain
            outDY *= gain
        }
        return (outDX, outDY)
    }

    private func clearFreezeLocked(now: CFAbsoluteTime) {
        hardLockUntil = 0
        softFreezeUntil = 0
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        postGateUntil = now + Self.postGateSec
    }

    private func beginClickHold() {
        lock.lock()
        dragArmed = false
        dragAccum = 0
        clickSettleUntil = CFAbsoluteTimeGetCurrent() + Self.clickSettleSec
        pendingDX = 0
        pendingDY = 0
        lock.unlock()
    }

    private func endClickHold() {
        lock.lock()
        dragArmed = false
        dragAccum = 0
        clickSettleUntil = CFAbsoluteTimeGetCurrent() + Self.releaseHardSec
        pendingDX = 0
        pendingDY = 0
        lock.unlock()
    }

    /// `false` = nuốt nhiễu khi bấm; `true` = đã vượt ngưỡng → cho drag.
    private func allowDragMotion(dx: Double, dy: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if dragArmed { return true }
        let now = CFAbsoluteTimeGetCurrent()
        /* Trong hard-lock / settle: không drag. */
        if now < hardLockUntil || now < clickSettleUntil { return false }
        dragAccum += hypot(dx, dy)
        if dragAccum < Self.dragThreshold { return false }
        dragArmed = true
        clearFreezeLocked(now: now)
        return true
    }

    private func activateSiri() {
        DispatchQueue.main.async {
            _ = NSWorkspace.shared.launchApplication("Siri")
        }
        logAsync(.ok, "Siri")
    }

    /// Gọi khi disconnect / fail / tắt mapping — tránh kẹt phím/chuột.
    func releaseAllInputs() {
        /* Disconnect: bỏ pending — không flush (tránh nhảy chuột sau mất kết nối). */
        discardPendingMotion()
        lock.lock()
        let vk = heldKey
        let flags = heldFlags
        let mb = mouseButtons
        heldKey = nil
        heldFlags = []
        mouseButtons = 0
        dragArmed = false
        dragAccum = 0
        clickSettleUntil = 0
        pendingDragButton = nil
        lastSmoothAt = 0
        lock.unlock()
        if let vk { key(vk, down: false, flags: flags) }
        if (mb & 1) != 0 { mouseClick(button: .left, down: false) }
        if (mb & 2) != 0 { mouseClick(button: .right, down: false) }
        if (mb & 4) != 0 { mouseClick(button: .center, down: false) }
        if (mb & 8) != 0 { mouseBack(down: false) }
    }

    /// Cocoa global (bottom-left) spanning all displays.
    private static func desktopQuartzBounds() -> CGRect {
        guard let primary = NSScreen.screens.first else { return .null }
        var bounds = CGRect.null
        for s in NSScreen.screens {
            // Quartz: origin = top-left primary; Y xuống dưới.
            let top = primary.frame.maxY - s.frame.maxY
            let r = CGRect(x: s.frame.minX, y: top, width: s.frame.width, height: s.frame.height)
            bounds = bounds.union(r)
        }
        return bounds
    }

    /// Luôn flip theo screens[0] (primary/menu bar) — KHÔNG dùng NSScreen.main (đổi theo focus).
    private static func cocoaToQuartz(_ p: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return p }
        return CGPoint(x: p.x, y: primary.frame.maxY - p.y)
    }

    private func notePointerActivity() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if now - lastPointerActivityAt < Self.pointerActivityMinInterval {
            lock.unlock()
            return
        }
        lastPointerActivityAt = now
        lock.unlock()
        onRemotePointerActivity?()
    }

    private func moveMouse(dx: Double, dy: Double, dragButton: CGMouseButton?) {
        notePointerActivity()
        let loc = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first else { return }
        var pos = CGPoint(x: loc.x + dx, y: (primary.frame.maxY - loc.y) + dy)
        let desk = Self.desktopQuartzBounds()
        if !desk.isNull && !desk.isInfinite {
            pos.x = min(max(pos.x, desk.minX), desk.maxX - 1)
            pos.y = min(max(pos.y, desk.minY), desk.maxY - 1)
        }
        let type: CGEventType
        let button: CGMouseButton
        if let dragButton {
            button = dragButton
            switch dragButton {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            default: type = .otherMouseDragged
            }
        } else {
            type = .mouseMoved
            button = .left
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        if type == .otherMouseDragged {
            ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        }
        ev.post(tap: .cghidEventTap)
    }
    private func mouseClick(button: CGMouseButton, down: Bool) {
        let loc = NSEvent.mouseLocation
        var pos = Self.cocoaToQuartz(loc)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        var count = mouseClickCount
        if down {
            let interval = NSEvent.doubleClickInterval
            let sameBtn = lastMouseDownButton.map { $0.rawValue == button.rawValue } ?? false
            let dist = hypot(pos.x - lastMouseDownQuartz.x, pos.y - lastMouseDownQuartz.y)
            if sameBtn, dist <= 10, (now - lastMouseDownUptime) <= interval {
                count += 1
                pos = lastMouseDownQuartz
            } else {
                count = 1
                lastMouseDownQuartz = pos
            }
            mouseClickCount = count
            lastMouseDownUptime = now
            lastMouseDownButton = button
        } else {
            count = mouseClickCount
        }
        lock.unlock()

        let type: CGEventType
        switch button {
        case .left: type = down ? .leftMouseDown : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: count)
        ev.post(tap: .cghidEventTap)
    }

    /// Nút Back trên chuột (XButton1 / buttonNumber 3) — browser Back, v.v.
    private func mouseBack(down: Bool) {
        let loc = NSEvent.mouseLocation
        let pos = Self.cocoaToQuartz(loc)
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(
            mouseEventSource: src,
            mouseType: type,
            mouseCursorPosition: pos,
            mouseButton: .center
        ) else { return }
        ev.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        ev.setIntegerValueField(.mouseEventClickState, value: 1)
        ev.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        ev?.flags = flags
        ev?.post(tap: .cghidEventTap)
    }

    private func postMedia(_ key: Int32, down: Bool) {
        let keyCode = Int64(key)
        let keyState = down ? Int64(0xa) : Int64(0xb)
        let data1 = (keyCode << 16) | (keyState << 8)
        let mods: NSEvent.ModifierFlags = .init(rawValue: UInt(down ? 0xa00 : 0xb00))
        guard let ev = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: mods,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(data1),
            data2: -1
        )?.cgEvent else { return }
        ev.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
