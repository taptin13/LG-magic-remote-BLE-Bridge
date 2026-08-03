import AppKit
import ApplicationServices
import Combine

/// Converts BridgePacket → CGEvent via `keyMaps`.
/// Motion runs under lock — MainActor not required (smoother when BLE notifies pile up).
final class InputMapper: ObservableObject {
    @Published var enabled = false
    @Published private(set) var trusted = false
    @Published private(set) var status = "off"
    /// Air mouse: profile mouse bindings; motion only when enabled.
    @Published private(set) var mouseMode = false

    /// User intent to map — kept even when Accessibility is temporarily unavailable.
    private(set) var wantsEnabled = false

    var onLog: ((LogLevel, String) -> Void)?
    /// Current map lookup (provided by AppModel) — used only when cache is empty.
    var resolveMap: ((UInt16) -> KeyMapRow?)?
    /// Notify AppModel to show Magic pointer (only when remote is driving).
    var onRemotePointerActivity: (() -> Void)?
    /// Sync mark only — must run before posting synthetic CGEvents (beats NSEvent monitors).
    var onRemotePointerMark: (() -> Void)?

    private let lock = NSLock()
    private var heldKey: CGKeyCode?
    private var heldFlags: CGEventFlags = []
    private var mouseButtons: UInt16 = 0
    /// Keyboard-style autorepeat while remote button is held (uses System Settings rates).
    private var keyRepeatTimer: DispatchSourceTimer?
    private var keyRepeatVK: CGKeyCode?
    private var keyRepeatFlags: CGEventFlags = []
    private var mediaRepeatTimer: DispatchSourceTimer?
    private var mediaRepeatKey: Int32?
    private let keyRepeatQueue = DispatchQueue(label: "mr.key.repeat", qos: .userInteractive)
    private var enabledFlag = false
    private var trustedFlag = false
    private var smoothingFlag = true
    private var nativeScrollFlag = true
    private var mouseModeFlag = false
    /// Cached map — avoids resolveMap hopping to MainActor from BLE queue (deadlock).
    private var mapCache: [UInt16: KeyMapRow] = [:]

    private var mouseLeftCode: UInt16? = 0x8044
    private var mouseRightCode: UInt16? = 0x8043
    private var mouseBackCode: UInt16? = 0x8028

    /// Click / scroll / key: remote is hard to hold still → temporarily freeze motion.
    /// hardLock = cannot break (prevents hand-shake accumulation). softFreeze = break on a strong swipe.
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

    /// Click count for CGEvent (HID does not set clickState → apps miss double-click).
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
    /// System double-click window — keep pointer frozen during this interval.
    private static let doubleClickWindow: CFTimeInterval = 0.55
    /// A large motion packet counts as intentional swipe (not accumulated shake).
    private static let instantBreakMag: Double = 18
    /// Same-direction motion streak after hard-lock.
    private static let coherentBreakThreshold: Double = 55
    private static let motionGateEpsilon: Double = 0.8

    /// Display-paced smoothing: jittery BLE packets → subdivide at ~125Hz.
    private var pendingDX = 0.0
    private var pendingDY = 0.0
    /// BLE arrival times represented by the next visible smoothing step.
    private var pendingVisualStartsNs: [UInt64] = []
    /// nil = mouseMoved; left/right/center = correct *Dragged type.
    private var pendingDragButton: CGMouseButton?
    private var smoothTimer: DispatchSourceTimer?
    /// A one-shot timer is armed only while motion is pending. Keeping the
    /// source alive avoids DispatchSource suspend/resume imbalance.
    private var smoothTimerScheduled = false
    private var lastSmoothAt: CFAbsoluteTime = 0
    private var lastPointerActivityAt: CFAbsoluteTime = 0
    private let smoothQueue = DispatchQueue(label: "mr.mouse.smooth", qos: .userInteractive)

    /// High-precision cursor position. macOS quantizes the pointer to whole pixels, so
    /// re-reading it every tick throws away the fraction of each sub-pixel step and slow
    /// motion stalls completely. Carry the fraction here and resync only when something
    /// else (physical mouse, another app) actually moved the pointer.
    private var virtualPos = CGPoint.zero
    private var virtualPosValid = false
    private var lastMoveAt: CFAbsoluteTime = 0
    /// After remote drop/reconnect (or long idle), WindowServer sometimes keeps
    /// accepting CGEvent posts while the *visible* cursor stays frozen until a
    /// real HID move. Track so the next remote motion can re-associate.
    private var needsCursorResync = true
    /// Last integer pixel we warpped to — avoid flooding WindowServer at 250Hz.
    private var lastWarpPixel = CGPoint(x: -1, y: -1)
    /// Updated from MainActor — Associate only works while frontmost; warp is the
    /// reliable path for a menu-bar / accessory app.
    private var appIsActiveFlag = false
    private static let virtualResyncTolerance: Double = 2.0
    private static let virtualResyncIdleSec: CFTimeInterval = 0.35

    /// NSEvent timing properties are AppKit reads, but injection runs on the BLE and
    /// repeat queues — cache them on the MainActor instead of touching AppKit there.
    private var cachedKeyRepeatDelay: TimeInterval = 0.35
    private var cachedKeyRepeatInterval: TimeInterval = 0.05
    private var cachedDoubleClickInterval: TimeInterval = 0.5

    /// Adaptive tau by residual speed (low → smooth; fast → less lag).
    /// Match firmware MOTION_ACCUM_MAX — avoid clipping fast flicks on Mac side.
    private static let pendingMotionCap: Double = 2048
    private static let pointerActivityMinInterval: CFTimeInterval = 1.0 / 45.0

    /// XCTest launches the app as a test host on headless/ non-interactive
    /// runners. WindowServer cursor association/warping is not a valid test
    /// side effect and can terminate the host before the test bundle starts.
    private static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
    }

    private static func smoothTau(forSpeed speed: Double) -> CFTimeInterval {
        // Keep low-speed motion stable without leaving a visible trailing
        // feel. Faster motion gets a shorter tau to remain responsive.
        if speed < 3 { return 0.010 }
        if speed < 12 { return 0.006 }
        return 0.0035
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

    /// Refresh cached AppKit timings — must run on the MainActor.
    @MainActor
    func refreshSystemInputTimings() {
        let repeatDelay = NSEvent.keyRepeatDelay
        let repeatInterval = NSEvent.keyRepeatInterval
        let doubleClick = NSEvent.doubleClickInterval
        lock.lock()
        cachedKeyRepeatDelay = repeatDelay > 0.05 ? repeatDelay : 0.35
        cachedKeyRepeatInterval = repeatInterval > 0.01 ? repeatInterval : 0.05
        cachedDoubleClickInterval = doubleClick > 0.05 ? doubleClick : 0.5
        lock.unlock()
    }

    @MainActor
    func refreshTrust() {
        refreshSystemInputTimings()
        let ok = AXIsProcessTrusted()
        trusted = ok
        lock.lock()
        trustedFlag = ok
        lock.unlock()

        if wantsEnabled {
            if ok {
                if !enabled {
                    applyEnableIfTrusted(prompt: false)
                }
            } else if enabled {
                /* Lost Accessibility while mapping — stop injection, keep intent. */
                releaseAllInputs()
                stopSmoothTimer()
                enabled = false
                lock.lock()
                enabledFlag = false
                lock.unlock()
                status = "needs Accessibility"
                onLog?(.error, "Accessibility revoked — Map stays ON, waiting for permission")
            } else {
                status = "needs Accessibility"
            }
        } else if enabled && !ok {
            status = "needs Accessibility"
        }
    }

    @MainActor
    func setEnabled(_ on: Bool) {
        wantsEnabled = on
        if on {
            applyEnableIfTrusted(prompt: true)
        } else {
            releaseAllInputs()
            stopSmoothTimer()
            enabled = false
            lock.lock()
            enabledFlag = false
            lock.unlock()
            status = "off"
        }
    }

    @MainActor
    private func applyEnableIfTrusted(prompt: Bool) {
        let ok: Bool
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            ok = AXIsProcessTrustedWithOptions(opts)
        } else {
            ok = AXIsProcessTrusted()
        }
        trusted = ok
        lock.lock()
        trustedFlag = ok
        lock.unlock()
        guard ok else {
            enabled = false
            lock.lock()
            enabledFlag = false
            lock.unlock()
            status = "needs Accessibility"
            onLog?(.error, "Enable Accessibility for MagicRemoteBLE — will retry automatically")
            return
        }
        enabled = true
        lock.lock()
        enabledFlag = true
        lock.unlock()
        status = "mapping"
        ensureSmoothTimer()
        onLog?(.matrix, "Input ON — mapping from config")
    }

    func setMotionSmoothing(_ on: Bool) {
        lock.lock()
        smoothingFlag = on
        lock.unlock()
        if on {
            ensureSmoothTimer()
        } else {
            flushPendingMotion()
        }
    }

    func setNativeScroll(_ on: Bool) {
        lock.lock()
        nativeScrollFlag = on
        lock.unlock()
    }

    /// Call from MainActor when keyMaps change.
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
        let wasOn = mouseModeFlag
        mouseModeFlag = on
        /* Mode changes must drop click/freeze leftovers — otherwise a missed
           button-up (or a scroll hard-lock that kept refreshing) swallows every
           dx/dy until the user toggles Mouse a few times by luck. */
        hardLockUntil = 0
        softFreezeUntil = 0
        postGateUntil = 0
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        dragArmed = false
        dragAccum = 0
        clickSettleUntil = 0
        pendingDX = 0
        pendingDY = 0
        let dropped = pendingVisualStartsNs.count
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        pendingDragButton = nil
        let stuckButtons = mouseButtons
        if !on {
            mouseButtons = 0
        }
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)

        if !on, stuckButtons != 0 {
            if (stuckButtons & 1) != 0 { mouseClick(button: .left, down: false) }
            if (stuckButtons & 2) != 0 { mouseClick(button: .right, down: false) }
            if (stuckButtons & 4) != 0 { mouseClick(button: .center, down: false) }
            if (stuckButtons & 8) != 0 { mouseBack(down: false) }
        }
        if on {
            ensureSmoothTimer()
        }

        let publish = { [weak self] in
            guard let self else { return }
            if self.mouseMode != on { self.mouseMode = on }
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
        if wasOn != on {
            logAsync(.ok, on ? "Mouse mode ON — profile mouse bindings" : "Mouse mode OFF — keys follow map")
        }
    }

    /// Flag used for prefs / UI — never the delayed `@Published` copy alone.
    func isMouseModeEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mouseModeFlag
    }

    /// Call after launch, window focus, or BLE Ready — clears stale freezes and
    /// makes sure the smooth timer is alive so motion works without a Mouse toggle.
    func reassertInputPipeline() {
        lock.lock()
        hardLockUntil = 0
        softFreezeUntil = 0
        postGateUntil = 0
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        clickSettleUntil = 0
        needsCursorResync = true
        virtualPosValid = false
        lastWarpPixel = CGPoint(x: -1, y: -1)
        let mouseOn = mouseModeFlag
        lock.unlock()

        /* Keep XCTest focused on packet/input logic. The real cursor pipeline
           is exercised by the running app and requires an interactive
           WindowServer session, which GitHub Actions may not provide. */
        guard !Self.isTestHost else { return }

        if Thread.isMainThread {
            if mouseMode != mouseOn { mouseMode = mouseOn }
            appIsActiveFlag = NSApp.isActive
            wakeSystemCursor()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.mouseMode != mouseOn { self.mouseMode = mouseOn }
                self.lock.lock()
                self.appIsActiveFlag = NSApp.isActive
                self.lock.unlock()
                self.wakeSystemCursor()
            }
        }
        ensureSmoothTimer()
    }

    @MainActor
    func setAppActive(_ active: Bool) {
        lock.lock()
        appIsActiveFlag = active
        if active {
            needsCursorResync = true
            lastWarpPixel = CGPoint(x: -1, y: -1)
        }
        lock.unlock()
        if active { wakeSystemCursor() }
    }

    /// Mark cursor tracking dirty without releasing keys (remote session flap).
    func invalidateCursorTracking() {
        lock.lock()
        needsCursorResync = true
        virtualPosValid = false
        pendingDX = 0
        pendingDY = 0
        let dropped = pendingVisualStartsNs.count
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        pendingDragButton = nil
        lastWarpPixel = CGPoint(x: -1, y: -1)
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
    }

    /// After the remote has been quiet, the next motion must re-associate the
    /// system cursor — otherwise posts succeed but the visible pointer stays frozen
    /// until the user clicks the app (which runs reassertInputPipeline).
    func armCursorWakeIfIdle(seconds: CFTimeInterval) {
        lock.lock()
        let idle = lastMoveAt == 0 || (CFAbsoluteTimeGetCurrent() - lastMoveAt) >= seconds
        if idle {
            needsCursorResync = true
            lastWarpPixel = CGPoint(x: -1, y: -1)
        }
        lock.unlock()
    }

    /// Re-associate / nudge the system cursor.
    /// `CGAssociateMouseAndMouseCursorPosition` is documented to work only while the
    /// app is frontmost — for menu-bar / accessory mode the reliable move is warp.
    func wakeSystemCursor() {
        let work = { [weak self] in
            guard let self else { return }
            let loc = CGEvent(source: nil)?.location ?? .zero
            if let src = CGEventSource(stateID: .combinedSessionState) {
                src.localEventsSuppressionInterval = 0
            }
            CGAssociateMouseAndMouseCursorPosition(1)
            if loc.x.isFinite, loc.y.isFinite {
                CGWarpMouseCursorPosition(CGPoint(x: loc.x + 1, y: loc.y))
                CGAssociateMouseAndMouseCursorPosition(1)
                CGWarpMouseCursorPosition(loc)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            self.lock.lock()
            self.virtualPos = loc
            self.virtualPosValid = loc.x.isFinite && loc.y.isFinite
            self.lastMoveAt = CFAbsoluteTimeGetCurrent()
            self.needsCursorResync = false
            self.lastWarpPixel = CGPoint(x: loc.x.rounded(), y: loc.y.rounded())
            self.lock.unlock()
        }
        if Thread.isMainThread {
            work()
        } else {
            /* Warp/Associate are unreliable off the main thread and from a
               background accessory process — finish before the next post. */
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                work()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + .milliseconds(80))
        }
    }

    func setMouseBindings(_ bindings: MouseButtonBindings) {
        lock.lock()
        mouseLeftCode = bindings.left
        mouseRightCode = bindings.right
        mouseBackCode = bindings.back
        lock.unlock()
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

    /// Called from BLE queue (not MainActor) — mouse path takes priority.
    func handle(_ packet: BridgePacket) {
        lock.lock()
        let ok = enabledFlag && trustedFlag
        lock.unlock()
        guard ok else {
            if packet.type == .motion && (packet.dx != 0 || packet.dy != 0) {
                PerformanceMetrics.shared.visualMotionDropped()
            }
            return
        }
        switch packet.type {
        case .motion:
            applyMouse(packet)
        case .button:
            applyButton(code: packet.buttonCode, down: packet.buttonDown)
        case .voice:
            if packet.buttonDown { activateSiri() }
        default:
            break
        }
    }

    private func applyMouse(_ packet: BridgePacket) {
        let dx = Int(packet.dx), dy = Int(packet.dy), wheel = Int(packet.wheel)
        lock.lock()
        let mouseOn = mouseModeFlag
        let dragBtn = Self.dragButton(from: mouseButtons)
        let smooth = smoothingFlag
        let nativeScroll = nativeScrollFlag
        lock.unlock()

        if wheel != 0 {
            /* Hold the pointer still while scrolling — same idea as click settle.
               Firmware sends wheel on its own channel (dx/dy usually 0), so this
               does not get refreshed by every gyro packet. */
            freezeMotion(hard: Self.scrollHardSec, soft: 0, postGate: false)
            scroll(deltaY: Int32(wheel), native: nativeScroll)
        }

        /* Air mouse off → swallow dx/dy. */
        guard dx != 0 || dy != 0 else { return }
        guard mouseOn else {
            PerformanceMetrics.shared.visualMotionDropped()
            return
        }

        let holding = dragBtn != nil
        if holding && !allowDragMotion(dx: Double(dx), dy: Double(dy)) {
            discardPendingMotion()
            PerformanceMetrics.shared.visualMotionDropped()
            return
        }
        guard let gated = gatedMotion(dx: Double(dx), dy: Double(dy)) else {
            PerformanceMetrics.shared.visualMotionDropped()
            return
        }

        if smooth {
            lock.lock()
            pendingDX = Self.clampPending(pendingDX + gated.dx)
            pendingDY = Self.clampPending(pendingDY + gated.dy)
            pendingDragButton = dragBtn
            pendingVisualStartsNs.append(packet.receivedAtNs)
            lock.unlock()
            armSmoothTimer()
        } else {
            if moveMouse(dx: gated.dx, dy: gated.dy, dragButton: dragBtn) {
                PerformanceMetrics.shared.visualMotionPosted(receivedAtNs: [packet.receivedAtNs])
            } else {
                PerformanceMetrics.shared.visualMotionDropped()
            }
        }
    }

    /// Prefer L → R → Middle when multiple buttons held.
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
                lock.lock()
                let doubleClick = cachedDoubleClickInterval
                lock.unlock()
                freezeMotion(hard: max(Self.clickHardSec, doubleClick), soft: 0, postGate: false)
            } else {
                freezeMotion(hard: Self.clickHardSec, soft: Self.clickSoftSec)
            }
        } else {
            if alsoEndHoldIfUp { endClickHold() }
            markClickUp()
            freezeMotion(hard: Self.releaseHardSec, soft: 0, postGate: false)
        }
    }

    /// Mouse mode: profile mouseBindings. Otherwise: normal map (+ Siri / Mouse toggle).
    private func applyButton(code: UInt16, down: Bool) {
        lock.lock()
        let mouseOn = mouseModeFlag
        let leftCode = mouseLeftCode
        let rightCode = mouseRightCode
        let backCode = mouseBackCode
        lock.unlock()

        if mouseOn {
            if let leftCode, code == leftCode {
                setSyntheticMouseBit(1, down: down)
                lock.lock()
                let otherHeld = (mouseButtons & 0b110) != 0
                lock.unlock()
                handleClickEdge(button: .left, down: down, alsoEndHoldIfUp: !otherHeld)
                return
            }
            if let rightCode, code == rightCode {
                setSyntheticMouseBit(2, down: down)
                lock.lock()
                let otherHeld = (mouseButtons & 0b101) != 0
                lock.unlock()
                handleClickEdge(button: .right, down: down, alsoEndHoldIfUp: !otherHeld)
                return
            }
            if let backCode, code == backCode {
                setSyntheticMouseBit(8, down: down)
                mouseBack(down: down)
                freezeMotion(
                    hard: down ? Self.clickHardSec : Self.releaseHardSec,
                    soft: down ? Self.clickSoftSec : 0,
                    postGate: false
                )
                return
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
            lock.unlock()
            setMouseMode(next)
            return
        }

        if let media = Self.mediaHID[row.key] {
            if down {
                freezeMotion(hard: Self.keyHardSec, soft: Self.keySoftSec)
                postMedia(media, down: true)
                postMedia(media, down: false)
                startMediaRepeat(media)
            } else {
                stopMediaRepeat()
            }
            return
        }

        guard let vk = Self.hidToVK[row.key] else { return }
        var flags: CGEventFlags = []
        if (row.mod & 0x01) != 0 { flags.insert(.maskControl) }
        if (row.mod & 0x02) != 0 { flags.insert(.maskShift) }
        if (row.mod & 0x04) != 0 { flags.insert(.maskAlternate) }
        if (row.mod & 0x08) != 0 { flags.insert(.maskCommand) }

        if down {
            freezeMotion(hard: Self.keyHardSec, soft: Self.keySoftSec)
            /* New key while another held — release previous (decoder usually does this). */
            lock.lock()
            let prev = heldKey
            let prevFlags = heldFlags
            lock.unlock()
            if let prev, prev != vk {
                stopKeyRepeat()
                key(prev, down: false, flags: prevFlags)
            }
            key(vk, down: true, flags: flags)
            lock.lock()
            heldKey = vk
            heldFlags = flags
            lock.unlock()
            startKeyRepeat(vk: vk, flags: flags)
        } else {
            stopKeyRepeat()
            key(vk, down: false, flags: flags)
            lock.lock()
            if heldKey == vk {
                heldKey = nil
                heldFlags = []
            }
            lock.unlock()
        }
    }

    /// Both repeat timers are driven from the BLE queue but also torn down from the
    /// MainActor (`releaseAllInputs`), so every field they touch stays under `lock`
    /// and cancellation happens outside it.
    private func startKeyRepeat(vk: CGKeyCode, flags: CGEventFlags) {
        lock.lock()
        let delay = cachedKeyRepeatDelay
        let interval = cachedKeyRepeatInterval
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: keyRepeatQueue)
        t.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let code = self.keyRepeatVK, self.heldKey == code else {
                self.lock.unlock()
                return
            }
            let f = self.keyRepeatFlags
            self.lock.unlock()
            self.key(code, down: true, flags: f, autorepeat: true)
        }

        lock.lock()
        let previous = keyRepeatTimer
        keyRepeatTimer = t
        keyRepeatVK = vk
        keyRepeatFlags = flags
        lock.unlock()
        previous?.cancel()
        t.resume()
    }

    private func stopKeyRepeat() {
        lock.lock()
        let t = keyRepeatTimer
        keyRepeatTimer = nil
        keyRepeatVK = nil
        keyRepeatFlags = []
        lock.unlock()
        t?.cancel()
    }

    private func startMediaRepeat(_ media: Int32) {
        lock.lock()
        let delay = cachedKeyRepeatDelay
        let interval = cachedKeyRepeatInterval
        lock.unlock()

        let t = DispatchSource.makeTimerSource(queue: keyRepeatQueue)
        t.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let m = self.mediaRepeatKey
            self.lock.unlock()
            guard let m else { return }
            self.postMedia(m, down: true)
            self.postMedia(m, down: false)
        }

        lock.lock()
        let previous = mediaRepeatTimer
        mediaRepeatTimer = t
        mediaRepeatKey = media
        lock.unlock()
        previous?.cancel()
        t.resume()
    }

    private func stopMediaRepeat() {
        lock.lock()
        let t = mediaRepeatTimer
        mediaRepeatTimer = nil
        mediaRepeatKey = nil
        lock.unlock()
        t?.cancel()
    }

    private func setSyntheticMouseBit(_ bit: UInt16, down: Bool) {
        lock.lock()
        if down { mouseButtons |= bit } else { mouseButtons &= ~bit }
        lock.unlock()
    }

    private func ensureSmoothTimer() {
        lock.lock()
        guard smoothTimer == nil else {
            lock.unlock()
            return
        }
        let t = DispatchSource.makeTimerSource(queue: smoothQueue)
        t.setEventHandler { [weak self] in self?.smoothTick() }
        smoothTimer = t
        lock.unlock()
        t.resume()
    }

    /// Arm one 4 ms smoothing step. The next step is armed by `smoothTick`
    /// only if residual motion remains, so idle mapping has no periodic wakeup.
    private func armSmoothTimer() {
        ensureSmoothTimer()
        lock.lock()
        guard smoothingFlag, enabledFlag,
              let timer = smoothTimer,
              !smoothTimerScheduled else {
            lock.unlock()
            return
        }
        smoothTimerScheduled = true
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: .never, leeway: .microseconds(250))
    }

    private func armNextSmoothTimerIfNeeded() {
        lock.lock()
        guard smoothingFlag, enabledFlag,
              (pendingDX != 0 || pendingDY != 0),
              let timer = smoothTimer,
              !smoothTimerScheduled else {
            lock.unlock()
            return
        }
        smoothTimerScheduled = true
        lock.unlock()
        timer.schedule(deadline: .now() + .milliseconds(4), repeating: .never, leeway: .microseconds(250))
    }

    private func stopSmoothTimer() {
        lock.lock()
        let t = smoothTimer
        let dropped = pendingVisualStartsNs.count
        smoothTimer = nil
        smoothTimerScheduled = false
        pendingDX = 0
        pendingDY = 0
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        pendingDragButton = nil
        lastSmoothAt = 0
        virtualPosValid = false
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
        t?.cancel()
    }

    private func flushPendingMotion() {
        lock.lock()
        let dx = pendingDX, dy = pendingDY, drag = pendingDragButton
        let starts = pendingVisualStartsNs
        pendingDX = 0
        pendingDY = 0
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        pendingDragButton = nil
        lock.unlock()
        if dx != 0 || dy != 0,
           moveMouse(dx: dx, dy: dy, dragButton: drag) {
            PerformanceMetrics.shared.visualMotionPosted(receivedAtNs: starts)
        } else {
            PerformanceMetrics.shared.visualMotionDropped(starts.count)
        }
    }

    private func discardPendingMotion() {
        lock.lock()
        let dropped = pendingVisualStartsNs.count
        pendingDX = 0
        pendingDY = 0
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        pendingDragButton = nil
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
    }

    private func smoothTick() {
        lock.lock()
        smoothTimerScheduled = false
        let enabled = enabledFlag
        lock.unlock()
        guard enabled else { return }
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now < hardLockUntil || now < softFreezeUntil {
            let dropped = pendingVisualStartsNs.count
            pendingDX = 0
            pendingDY = 0
            pendingVisualStartsNs.removeAll(keepingCapacity: true)
            lock.unlock()
            PerformanceMetrics.shared.visualMotionDropped(dropped)
            return
        }
        let dx = pendingDX
        let dy = pendingDY
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
            dt = 0.004
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
        let starts = pendingVisualStartsNs
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        lock.unlock()

        var outX = stepX, outY = stepY
        if now < gateUntil {
            let t = max(0, (gateUntil - now) / Self.postGateSec)
            let gateGain = 1.0 - 0.75 * t
            outX *= gateGain
            outY *= gateGain
        }
        if outX != 0 || outY != 0 {
            if moveMouse(dx: outX, dy: outY, dragButton: drag) {
                PerformanceMetrics.shared.visualMotionPosted(receivedAtNs: starts)
            } else {
                PerformanceMetrics.shared.visualMotionDropped(starts.count)
            }
        } else {
            PerformanceMetrics.shared.visualMotionDropped(starts.count)
        }
        armNextSmoothTimerIfNeeded()
    }
    private func scroll(deltaY: Int32, native: Bool? = nil) {
        guard deltaY != 0 else { return }
        notePointerActivity(forceShow: true)
        let useNative: Bool
        if let native {
            useNative = native
        } else {
            lock.lock()
            useNative = nativeScrollFlag
            lock.unlock()
        }
        /* Native (macOS) = inverted (Natural Scrolling). Off = Windows direction. */
        let dy = useNative ? -deltaY : deltaY
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

    /// hard: no movement at all. soft: break only on strong/same-direction swipe (no shake accumulation).
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
            /* Stay frozen through soft — for double-click / scroll. */
            postGateUntil = 0
        }
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        pendingDX = 0
        pendingDY = 0
        let dropped = pendingVisualStartsNs.count
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
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

    /// `nil` = swallow; non-nil = motion after post-gate gain applied.
    private func gatedMotion(dx: Double, dy: Double) -> (dx: Double, dy: Double)? {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        let mag = hypot(dx, dy)

        if now < hardLockUntil {
            let dropped = pendingVisualStartsNs.count
            pendingDX = 0
            pendingDY = 0
            pendingVisualStartsNs.removeAll(keepingCapacity: true)
            coherentBreakAccum = 0
            lock.unlock()
            PerformanceMetrics.shared.visualMotionDropped(dropped)
            return nil
        }

        if now < softFreezeUntil {
            /* Early break only when: (1) single packet large enough, or (2) same-direction streak. */
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
                    let dropped = pendingVisualStartsNs.count
                    pendingDX = 0
                    pendingDY = 0
                    pendingVisualStartsNs.removeAll(keepingCapacity: true)
                    lock.unlock()
                    PerformanceMetrics.shared.visualMotionDropped(dropped)
                    return nil
                }
                clearFreezeLocked(now: now)
            }
        } else {
            coherentBreakAccum = 0
            if mag < Self.motionGateEpsilon {
                lock.unlock()
                return nil
            }
        }

        var outDX = dx, outDY = dy
        if now < postGateUntil {
            let t = max(0, (postGateUntil - now) / Self.postGateSec)
            let gain = 1.0 - 0.85 * t
            outDX *= gain
            outDY *= gain
        }
        lock.unlock()
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
        let dropped = pendingVisualStartsNs.count
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
    }

    private func endClickHold() {
        lock.lock()
        dragArmed = false
        dragAccum = 0
        clickSettleUntil = CFAbsoluteTimeGetCurrent() + Self.releaseHardSec
        pendingDX = 0
        pendingDY = 0
        let dropped = pendingVisualStartsNs.count
        pendingVisualStartsNs.removeAll(keepingCapacity: true)
        lock.unlock()
        PerformanceMetrics.shared.visualMotionDropped(dropped)
    }

    /// `false` = swallow noise while pressing; `true` = passed threshold → allow drag.
    private func allowDragMotion(dx: Double, dy: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if dragArmed { return true }
        let now = CFAbsoluteTimeGetCurrent()
        /* During hard-lock / settle: no drag. */
        if now < hardLockUntil || now < clickSettleUntil { return false }
        dragAccum += hypot(dx, dy)
        if dragAccum < Self.dragThreshold { return false }
        dragArmed = true
        clearFreezeLocked(now: now)
        return true
    }

    private func activateSiri() {
        DispatchQueue.main.async {
            let workspace = NSWorkspace.shared
            let siriURL =
                workspace.urlForApplication(withBundleIdentifier: "com.apple.Siri")
                ?? URL(fileURLWithPath: "/System/Applications/Siri.app")
            workspace.openApplication(at: siriURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        logAsync(.ok, "Siri")
    }

    /// Call on disconnect / fail / mapping off — avoid stuck keys/mouse.
    func releaseAllInputs() {
        /* Disconnect: drop pending — do not flush (avoids cursor jump after disconnect). */
        discardPendingMotion()
        stopKeyRepeat()
        stopMediaRepeat()
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
        virtualPosValid = false
        needsCursorResync = true
        hardLockUntil = 0
        softFreezeUntil = 0
        postGateUntil = 0
        coherentBreakAccum = 0
        lastBreakDX = 0
        lastBreakDY = 0
        clickSettleUntil = 0
        lock.unlock()
        if let vk { key(vk, down: false, flags: flags) }
        if (mb & 1) != 0 { mouseClick(button: .left, down: false) }
        if (mb & 2) != 0 { mouseClick(button: .right, down: false) }
        if (mb & 4) != 0 { mouseClick(button: .center, down: false) }
        if (mb & 8) != 0 { mouseBack(down: false) }
    }

    /// Cocoa global (bottom-left) spanning all displays.
    private static func desktopQuartzBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return .null }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        var bounds = CGRect.null
        for id in displays.prefix(Int(count)) {
            bounds = bounds.union(CGDisplayBounds(id))
        }
        return bounds
    }

    /// Quartz-space pointer location. Prefers the sub-pixel accumulator so clicks land
    /// exactly where motion left the pointer, and never reads AppKit off the MainActor.
    private func currentQuartzLocation() -> CGPoint {
        lock.lock()
        let virtual = virtualPos
        let usable = virtualPosValid
            && CFAbsoluteTimeGetCurrent() - lastMoveAt <= Self.virtualResyncIdleSec
        lock.unlock()
        if usable { return virtual }
        return CGEvent(source: nil)?.location ?? virtual
    }

    private func notePointerActivity(forceShow: Bool = false) {
        /* Sync mark first — synthetic clicks/scrolls hit our global monitors. */
        onRemotePointerMark?()
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let hop = forceShow || (now - lastPointerActivityAt >= Self.pointerActivityMinInterval)
        if hop { lastPointerActivityAt = now }
        lock.unlock()
        if hop {
            onRemotePointerActivity?()
        }
    }

    @discardableResult
    private func moveMouse(dx: Double, dy: Double, dragButton: CGMouseButton?) -> Bool {
        notePointerActivity()
        guard dx.isFinite, dy.isFinite else { return false }

        lock.lock()
        let idleGap = lastMoveAt == 0 || (CFAbsoluteTimeGetCurrent() - lastMoveAt) > 0.8
        let mustWake = needsCursorResync || !virtualPosValid || idleGap
        lock.unlock()
        if mustWake {
            wakeSystemCursor()
        }

        /* CGEvent location is Quartz (Y down) and safe off MainActor — avoid NSEvent/NSScreen here. */
        guard let probe = CGEvent(source: nil) else { return false }
        let actual = probe.location
        let desk = Self.desktopQuartzBounds()
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let drifted =
            abs(actual.x - virtualPos.x) > Self.virtualResyncTolerance
            || abs(actual.y - virtualPos.y) > Self.virtualResyncTolerance
        if !virtualPosValid || drifted || now - lastMoveAt > Self.virtualResyncIdleSec {
            virtualPos = actual
        }
        virtualPos.x += dx
        virtualPos.y += dy
        if !desk.isNull && !desk.isInfinite {
            virtualPos.x = min(max(virtualPos.x, desk.minX), desk.maxX - 1)
            virtualPos.y = min(max(virtualPos.y, desk.minY), desk.maxY - 1)
        }
        virtualPosValid = true
        lastMoveAt = now
        let pos = virtualPos
        let prevWarp = lastWarpPixel
        lock.unlock()

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

        /* Menu-bar / accessory apps are usually not frontmost.
           CGEvent mouseMoved alone updates the event location but often leaves the
           *visible* cursor stuck until a real HID move — matching the bug report.
           Warp drives the on-screen cursor; mouseMoved still notifies apps. */
        let pixel = CGPoint(x: pos.x.rounded(.toNearestOrAwayFromZero),
                            y: pos.y.rounded(.toNearestOrAwayFromZero))
        if pixel != prevWarp {
            if let suppress = CGEventSource(stateID: .combinedSessionState) {
                suppress.localEventsSuppressionInterval = 0
            }
            CGWarpMouseCursorPosition(pixel)
            /* Cancels the default ~0.25s hardware-event suppression after warp. */
            CGAssociateMouseAndMouseCursorPosition(1)
            lock.lock()
            lastWarpPixel = pixel
            lock.unlock()
        }

        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: button) else { return false }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64((pos.x - actual.x).rounded()))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64((pos.y - actual.y).rounded()))
        if type == .otherMouseDragged {
            ev.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        }
        ev.post(tap: .cghidEventTap)
        PerformanceMetrics.shared.eventPosted()
        return true
    }
    private func mouseClick(button: CGMouseButton, down: Bool) {
        /* Mark before posting — synthetic clicks hit our global monitors as mouseDown. */
        notePointerActivity(forceShow: true)
        var pos = currentQuartzLocation()
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        var count = mouseClickCount
        if down {
            let interval = cachedDoubleClickInterval
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

    /// Back button on mouse (XButton1 / buttonNumber 3) — browser Back, etc.
    private func mouseBack(down: Bool) {
        notePointerActivity(forceShow: true)
        let pos = currentQuartzLocation()
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

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], autorepeat: Bool = false) {
        let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        ev?.flags = flags
        if down && autorepeat {
            ev?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        ev?.post(tap: .cghidEventTap)
    }

    /// `NSEvent.otherEvent` is the only way to build a system-defined media event, and
    /// it is AppKit — hop to the MainActor instead of calling it from the BLE queue.
    private func postMedia(_ key: Int32, down: Bool) {
        if Thread.isMainThread {
            postMediaOnMain(key, down: down)
        } else {
            DispatchQueue.main.async { [weak self] in self?.postMediaOnMain(key, down: down) }
        }
    }

    private func postMediaOnMain(_ key: Int32, down: Bool) {
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
