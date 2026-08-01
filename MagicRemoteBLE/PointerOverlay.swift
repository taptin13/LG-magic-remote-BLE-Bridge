import AppKit
import CoreGraphics
import Darwin

/// Large pointer when the remote is driving.
///
/// Primary path scales the real system cursor via WindowServer, so the Dock, fullscreen
/// video and rapid clicks cannot reveal a default-size pointer. The overlay panel below
/// is the fallback for machines where the scaling symbols are missing.
final class PointerOverlayController {
    private let cursorScale = SystemCursorScale()
    private var scaleRevertTimer: Timer?
    private var scaleMonitors: [Any] = []
    /// Revert to the user's pointer size once the remote stops driving.
    private static let scaleRevertSec: CFTimeInterval = 2.0

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var followTimer: Timer?
    private var idleHideTimer: Timer?
    private var featureOn = false
    private var visuallyShown = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cursorInBgEnabled = false
    private var nsCursorHidden = false
    private var cgHidden = false
    private var hiddenDisplays: [CGDirectDisplayID] = []
    private var cachedArrow: NSImage?
    private var cachedScale: CGFloat = 0
    private var hotSpot = CGPoint(x: 0, y: 0) // tip offset within panel (Cocoa: bottom-left origin)
    private var screenObservers: [NSObjectProtocol] = []

    /// Remote timestamp (thread-safe) — distinguishes remote CGEvent vs physical mouse.
    private let remoteLock = NSLock()
    private var lastRemoteActivityAt: CFAbsoluteTime = 0
    /// Physical mouse hides overlay only when remote idle ≥ this threshold.
    /// Must cover multi-click gaps and synthetic click → NSEvent monitor latency.
    private static let physicalQuietSec: CFTimeInterval = 1.25
    private static let idleHideSec: CFTimeInterval = 1.5
    private static let showHopMinInterval: CFTimeInterval = 1.0 / 60.0
    private var lastShowHopAt: CFAbsoluteTime = 0
    /// Extra CGDisplayHideCursor calls when Dock/apps re-show the cursor.
    private var cgHideDepth = 0
    private var nsHideDepth = 0

    /// Arrow scale factor.
    var size: CGFloat = 2.6 {
        didSet {
            guard abs(oldValue - size) > 0.01 else { return }
            if usesSystemScale {
                if cursorScale.isScaled { cursorScale.apply(Float(size)) }
                return
            }
            cachedArrow = nil
            rebuildImageIfNeeded()
            if visuallyShown { tick() }
        }
    }

    private var usesSystemScale: Bool { cursorScale.isAvailable }

    func setFeatureEnabled(_ on: Bool) {
        featureOn = on
        if usesSystemScale {
            if on {
                installScaleMonitors()
            } else {
                tearDownScaleMonitors()
                scaleRevertTimer?.invalidate()
                scaleRevertTimer = nil
                cursorScale.restore()
            }
            return
        }
        if on {
            enableCursorControlInBackground()
            installMonitors()
            installScreenObservers()
        } else {
            tearDownScreenObservers()
            tearDownMonitors()
            hideVisual()
        }
    }

    /// Physical mouse / trackpad use reverts to the user's own pointer size.
    private func installScaleMonitors() {
        guard scaleMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .mouseMoved,
        ]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] ev in
            self?.onPhysicalInputWhileScaled(ev)
        }) {
            scaleMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] ev in
            self?.onPhysicalInputWhileScaled(ev)
            return ev
        }) {
            scaleMonitors.append(l)
        }
    }

    private func tearDownScaleMonitors() {
        for m in scaleMonitors { NSEvent.removeMonitor(m) }
        scaleMonitors.removeAll()
    }

    private func onPhysicalInputWhileScaled(_ event: NSEvent) {
        guard featureOn, cursorScale.isScaled else { return }
        /* Remote motion/clicks are CGEvent posts from this process — those echo
           into NSEvent monitors and must not count as "physical". Real HID
           events carry pid 0 (or another process). */
        if Self.isSynthesizedByThisProcess(event) { return }
        /* Tiny echo window for events that lack a usable source pid. */
        if secondsSinceRemote() < 0.08 { return }

        let restore = { [weak self] in
            guard let self, self.featureOn, self.cursorScale.isScaled else { return }
            self.cursorScale.restore()
            self.scaleRevertTimer?.invalidate()
            self.scaleRevertTimer = nil
        }
        if Thread.isMainThread {
            restore()
        } else {
            DispatchQueue.main.async(execute: restore)
        }
    }

    /// True when the event was produced by our own CGEvent posts (airmouse / clicks).
    private static func isSynthesizedByThisProcess(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        let pid = cg.getIntegerValueField(.eventSourceUnixProcessID)
        if pid == 0 { return false }
        return pid == Int64(getpid())
    }

    private func applySystemScale() {
        cursorScale.apply(Float(size))
        scaleRevertTimer?.invalidate()
        scaleRevertTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scaleRevertSec,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            if self.secondsSinceRemote() < Self.scaleRevertSec * 0.9 {
                self.applySystemScale()
                return
            }
            self.cursorScale.restore()
        }
        if let scaleRevertTimer {
            RunLoop.main.add(scaleRevertTimer, forMode: .common)
        }
    }

    /// Called on quit — never leave the user with an oversized pointer.
    func restoreSystemPointerSize() {
        scaleRevertTimer?.invalidate()
        scaleRevertTimer = nil
        cursorScale.restore()
    }

    /// Call after display reconfiguration / wake — restore cursor then re-apply if overlay showing.
    func recoverAfterDisplayChange() {
        guard featureOn else { return }
        if usesSystemScale {
            if cursorScale.isScaled { cursorScale.apply(Float(size)) }
            return
        }
        let wasShown = visuallyShown
        if cgHidden || nsCursorHidden {
            restoreSystemCursor()
        }
        if wasShown {
            panel?.orderFrontRegardless()
            if panel?.isVisible == true {
                forceHideSystemCursor()
                ensureFollowTimer()
                tick()
            } else {
                /* Overlay failed to show — keep system cursor visible. */
                visuallyShown = false
                followTimer?.invalidate()
                followTimer = nil
            }
        }
    }

    /// Call from any queue BEFORE posting CGEvent — marks remote as driving.
    func markRemoteDriving() {
        remoteLock.lock()
        lastRemoteActivityAt = CFAbsoluteTimeGetCurrent()
        remoteLock.unlock()
    }

    /// Show overlay (main). May be called after markRemoteDriving.
    func noteRemoteActivity() {
        guard featureOn else { return }
        markRemoteDriving()
        if usesSystemScale {
            if Thread.isMainThread {
                applySystemScale()
            } else {
                DispatchQueue.main.async { [weak self] in self?.applySystemScale() }
            }
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let mustShow = !visuallyShown
        let hopDue = now - lastShowHopAt >= Self.showHopMinInterval
        guard mustShow || hopDue else { return }
        lastShowHopAt = now
        let work = { [weak self] in
            self?.showVisual()
            self?.scheduleIdleHide()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func showVisual() {
        if panel == nil { buildPanel() }
        rebuildImageIfNeeded()
        if visuallyShown {
            ensurePanelVisibleThenHideCursor()
            ensureFollowTimer()
            tick()
            return
        }
        visuallyShown = true
        panel?.orderFrontRegardless()
        ensureFollowTimer()
        tick()
        ensurePanelVisibleThenHideCursor()
    }

    /// Only hide the system cursor after the overlay panel is actually on-screen.
    private func ensurePanelVisibleThenHideCursor() {
        panel?.orderFrontRegardless()
        if panel?.isVisible == true {
            forceHideSystemCursor()
            return
        }
        /* Brief retry — fullscreen / Space transitions can delay panel visibility. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.featureOn, self.visuallyShown else { return }
            self.panel?.orderFrontRegardless()
            if self.panel?.isVisible == true {
                self.forceHideSystemCursor()
            } else {
                /* Do not leave the user without any cursor. */
                self.restoreSystemCursor()
            }
        }
    }

    private func hideVisual() {
        idleHideTimer?.invalidate()
        idleHideTimer = nil
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        visuallyShown = false
        restoreSystemCursor()
    }

    private func scheduleIdleHide() {
        idleHideTimer?.invalidate()
        idleHideTimer = Timer.scheduledTimer(withTimeInterval: Self.idleHideSec, repeats: false) { [weak self] _ in
            guard let self else { return }
            /* Hide only if remote is truly idle. */
            if self.secondsSinceRemote() < Self.idleHideSec * 0.85 {
                self.scheduleIdleHide()
                return
            }
            self.hideVisual()
        }
        if let idleHideTimer {
            RunLoop.main.add(idleHideTimer, forMode: .common)
        }
    }

    private func ensureFollowTimer() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let followTimer {
            RunLoop.main.add(followTimer, forMode: .common)
        }
    }

    private func tick() {
        guard let panel, visuallyShown else { return }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        /* Always re-assert hide — Dock / clicks re-show the system cursor. */
        forceHideSystemCursor()
        let loc = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: loc.x - hotSpot.x, y: loc.y - hotSpot.y))
        /* Extend idle timer while remote is still driving. */
        if secondsSinceRemote() < 0.35 {
            scheduleIdleHide()
        }
    }

    private func secondsSinceRemote() -> CFTimeInterval {
        remoteLock.lock()
        let t = lastRemoteActivityAt
        remoteLock.unlock()
        guard t > 0 else { return .greatestFiniteMagnitude }
        return CFAbsoluteTimeGetCurrent() - t
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        /* Above Dock / menu / video controls */
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let iv = NSImageView(frame: panel.contentView?.bounds ?? .zero)
        iv.imageScaling = .scaleNone
        iv.autoresizingMask = [.width, .height]
        panel.contentView = iv

        self.panel = panel
        self.imageView = iv
    }

    private func rebuildImageIfNeeded() {
        let scale = max(size, 1.2)
        if cachedArrow != nil, abs(cachedScale - scale) < 0.01, panel != nil { return }

        let base = NSCursor.arrow
        let src = base.image
        let srcSize = src.size
        guard srcSize.width > 0, srcSize.height > 0 else { return }

        let dstSize = NSSize(width: ceil(srcSize.width * scale), height: ceil(srcSize.height * scale))
        let img = NSImage(size: dstSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(
            in: NSRect(origin: .zero, size: dstSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .sourceOver,
            fraction: 1
        )
        img.unlockFocus()

        cachedArrow = img
        cachedScale = scale
        /* NSCursor.hotSpot: top-left image origin. Panel/Cocoa: bottom-left origin → flip Y. */
        let tipFromTopX = base.hotSpot.x * scale
        let tipFromTopY = base.hotSpot.y * scale
        hotSpot = CGPoint(x: tipFromTopX, y: dstSize.height - tipFromTopY)

        guard let panel else { return }
        var f = panel.frame
        f.size = dstSize
        panel.setFrame(f, display: true)
        imageView?.image = img
        imageView?.frame = NSRect(origin: .zero, size: dstSize)
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        /* Buttons/drag only — do NOT listen to mouseMoved (remote CGEvent also emits mouseMoved). */
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.onLikelyPhysicalInput()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.onLikelyPhysicalInput()
            return ev
        }
    }

    private func tearDownMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func installScreenObservers() {
        guard screenObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.recoverAfterDisplayChange() }
        }
        screenObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil, using: handler
        ))
        screenObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: nil, using: handler
        ))
    }

    private func tearDownScreenObservers() {
        let center = NotificationCenter.default
        for obs in screenObservers {
            center.removeObserver(obs)
        }
        screenObservers.removeAll()
    }

    private func onLikelyPhysicalInput() {
        guard featureOn, visuallyShown else { return }
        /* Remote just drove (remote click/scroll also marks) → ignore. */
        if secondsSinceRemote() < Self.physicalQuietSec { return }
        hideVisual()
    }

    /// Best-effort private CGS hook so `NSCursor.hide` works while this app is backgrounded.
    /// If symbols are missing/ABI-changed, public APIs below still run (overlay remains usable).
    private var privateCursorAPIProbed = false
    private var privateCursorAPIAvailable = false

    private func enableCursorControlInBackground() {
        if cursorInBgEnabled { return }
        if !privateCursorAPIProbed {
            privateCursorAPIProbed = true
            privateCursorAPIAvailable = probeSetsCursorInBackground()
            if !privateCursorAPIAvailable {
                NSLog("PointerOverlay: SetsCursorInBackground unavailable — using NSCursor.hide + CGDisplayHideCursor only")
            }
        }
        guard privateCursorAPIAvailable else { return }
        if applySetsCursorInBackground() {
            cursorInBgEnabled = true
        }
    }

    private func probeSetsCursorInBackground() -> Bool {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "CGSSetConnectionProperty") != nil
            && dlsym(handle, "_CGSDefaultConnection") != nil
    }

    private func applySetsCursorInBackground() -> Bool {
        typealias ConnID = Int32
        typealias SetPropFn = @convention(c) (ConnID, ConnID, CFString, CFBoolean) -> Int32
        typealias DefaultConnFn = @convention(c) () -> ConnID
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard
            let setSym = dlsym(handle, "CGSSetConnectionProperty"),
            let defSym = dlsym(handle, "_CGSDefaultConnection")
        else { return false }
        let setProp = unsafeBitCast(setSym, to: SetPropFn.self)
        let defConn = unsafeBitCast(defSym, to: DefaultConnFn.self)
        let cid = defConn()
        let rc = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        return rc == 0
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func forceHideSystemCursor() {
        enableCursorControlInBackground()
        let blank = NSCursor(
            image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
            hotSpot: .zero
        )
        blank.set()

        /* Dock / multi-click re-show the system cursor. Without CGCursorIsVisible
         * (removed on modern macOS), periodically reset hide depth to 1 while the
         * remote is driving or the pointer is over Dock/menu chrome. */
        let aggressive = secondsSinceRemote() < 0.9 || isInSystemChrome(NSEvent.mouseLocation)
        let now = CFAbsoluteTimeGetCurrent()
        if aggressive, now - lastReassertAt >= 0.05 {
            lastReassertAt = now
            reassertSingleHide(blank: blank)
            return
        }

        if nsHideDepth == 0 {
            NSCursor.hide()
            nsHideDepth = 1
        }
        if cgHideDepth == 0 {
            let displays = activeDisplayIDs()
            for id in displays {
                _ = CGDisplayHideCursor(id)
            }
            hiddenDisplays = displays
            cgHideDepth = 1
        }
        nsCursorHidden = nsHideDepth > 0
        cgHidden = cgHideDepth > 0
    }

    private var lastReassertAt: CFAbsoluteTime = 0

    private func reassertSingleHide(blank: NSCursor) {
        blank.set()
        if nsHideDepth > 0 {
            for _ in 0..<nsHideDepth { NSCursor.unhide() }
        }
        NSCursor.hide()
        nsHideDepth = 1

        var ids = Set(hiddenDisplays)
        ids.formUnion(activeDisplayIDs())
        if cgHideDepth > 0 {
            for _ in 0..<cgHideDepth {
                for id in ids {
                    _ = CGDisplayShowCursor(id)
                }
            }
        }
        let displays = activeDisplayIDs()
        for id in displays {
            _ = CGDisplayHideCursor(id)
        }
        hiddenDisplays = displays
        cgHideDepth = 1
        nsCursorHidden = true
        cgHidden = true
    }

    /// Dock / menu bar strips — WindowServer forces the default cursor here.
    private func isInSystemChrome(_ loc: NSPoint) -> Bool {
        let screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return false }
        let full = screen.frame
        let vis = screen.visibleFrame
        let pad: CGFloat = 6
        if vis.minY > full.minY + 1, loc.y <= vis.minY + pad { return true }      // bottom Dock
        if vis.maxY < full.maxY - 1, loc.y >= vis.maxY - pad { return true }      // menu bar
        if vis.minX > full.minX + 1, loc.x <= vis.minX + pad { return true }      // left Dock
        if vis.maxX < full.maxX - 1, loc.x >= vis.maxX - pad { return true }      // right Dock
        return false
    }

    private func restoreSystemCursor() {
        if nsHideDepth > 0 {
            for _ in 0..<nsHideDepth {
                NSCursor.unhide()
            }
            nsHideDepth = 0
            nsCursorHidden = false
        }
        if cgHideDepth > 0 {
            var ids = Set(hiddenDisplays)
            ids.formUnion(activeDisplayIDs())
            ids.insert(CGMainDisplayID())
            for _ in 0..<cgHideDepth {
                for id in ids {
                    _ = CGDisplayShowCursor(id)
                }
            }
            cgHideDepth = 0
            hiddenDisplays = []
            cgHidden = false
        }
        NSCursor.arrow.set()
    }

    deinit {
        followTimer?.invalidate()
        idleHideTimer?.invalidate()
        scaleRevertTimer?.invalidate()
        tearDownScreenObservers()
        tearDownMonitors()
        tearDownScaleMonitors()
        cursorScale.restore()
        restoreSystemCursor()
    }
}
