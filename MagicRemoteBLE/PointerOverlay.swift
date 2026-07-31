import AppKit
import CoreGraphics
import Darwin

/// Large pointer when the remote is driving.
/// Uses arrow overlay (not just NSCursor) so it stays visible over Dock / YouTube / Chrome.
final class PointerOverlayController {
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
    private var cachedArrow: NSImage?
    private var cachedScale: CGFloat = 0
    private var hotSpot = CGPoint(x: 0, y: 0) // tip offset within panel (Cocoa: bottom-left origin)

    /// Remote timestamp (thread-safe) — distinguishes remote CGEvent vs physical mouse.
    private let remoteLock = NSLock()
    private var lastRemoteActivityAt: CFAbsoluteTime = 0
    /// Physical mouse hides overlay only when remote idle ≥ this threshold.
    private static let physicalQuietSec: CFTimeInterval = 0.45
    private static let idleHideSec: CFTimeInterval = 1.0

    /// Arrow scale factor.
    var size: CGFloat = 2.6 {
        didSet {
            if abs(oldValue - size) > 0.01 {
                cachedArrow = nil
                rebuildImageIfNeeded()
                if visuallyShown { tick() }
            }
        }
    }

    func setFeatureEnabled(_ on: Bool) {
        featureOn = on
        if on {
            enableCursorControlInBackground()
            installMonitors()
        } else {
            tearDownMonitors()
            hideVisual()
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
        guard !visuallyShown else {
            forceHideSystemCursor()
            ensureFollowTimer()
            tick()
            return
        }
        visuallyShown = true
        panel?.orderFrontRegardless()
        forceHideSystemCursor()
        ensureFollowTimer()
        tick()
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
        forceHideSystemCursor()
        let loc = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: loc.x - hotSpot.x, y: loc.y - hotSpot.y))
        /* Extend idle timer while remote is still driving. */
        if secondsSinceRemote() < 0.2 {
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

    private func forceHideSystemCursor() {
        enableCursorControlInBackground()
        /* Public fallback path — always attempted even when private CGS is unavailable. */
        let blank = NSCursor(
            image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
            hotSpot: .zero
        )
        blank.set()
        if !nsCursorHidden {
            NSCursor.hide()
            nsCursorHidden = true
        }
        if !cgHidden {
            _ = CGDisplayHideCursor(CGMainDisplayID())
            cgHidden = true
        }
    }

    private func restoreSystemCursor() {
        if nsCursorHidden {
            NSCursor.unhide()
            nsCursorHidden = false
        }
        if cgHidden {
            _ = CGDisplayShowCursor(CGMainDisplayID())
            cgHidden = false
        }
        NSCursor.arrow.set()
    }

    deinit {
        followTimer?.invalidate()
        idleHideTimer?.invalidate()
        tearDownMonitors()
        restoreSystemCursor()
    }
}
