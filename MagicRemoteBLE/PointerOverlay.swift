import AppKit
import CoreGraphics
import Darwin

/// Con trỏ lớn khi remote điều khiển.
/// Dùng overlay mũi tên (không chỉ NSCursor) để vẫn hiện trên Dock / YouTube / Chrome.
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
    private var hotSpot = CGPoint(x: 0, y: 0) // offset tip trong panel (Cocoa: gốc dưới-trái)

    /// Timestamp remote (thread-safe) — dùng để phân biệt CGEvent remote vs chuột thật.
    private let remoteLock = NSLock()
    private var lastRemoteActivityAt: CFAbsoluteTime = 0
    /// Chuột thật chỉ ẩn overlay khi remote im ≥ ngưỡng này.
    private static let physicalQuietSec: CFTimeInterval = 0.45
    private static let idleHideSec: CFTimeInterval = 1.0

    /// Hệ số phóng mũi tên.
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

    /// Gọi từ bất kỳ queue nào TRƯỚC khi post CGEvent — đánh dấu remote đang lái.
    func markRemoteDriving() {
        remoteLock.lock()
        lastRemoteActivityAt = CFAbsoluteTimeGetCurrent()
        remoteLock.unlock()
    }

    /// Hiện overlay (main). Có thể gọi sau markRemoteDriving.
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
            /* Chỉ ẩn nếu remote thật sự im. */
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
        /* Gia hạn idle khi remote còn đang lái. */
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
        /* Cao hơn Dock / menu / video controls */
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
        /* NSCursor.hotSpot: gốc trên-trái ảnh. Panel/Cocoa: gốc dưới-trái → đổi Y. */
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
        /* Chỉ nút/kéo — KHÔNG listen mouseMoved (CGEvent remote cũng phát mouseMoved). */
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
        /* Remote vừa lái (click/scroll từ remote cũng mark) → bỏ qua. */
        if secondsSinceRemote() < Self.physicalQuietSec { return }
        hideVisual()
    }

    private func enableCursorControlInBackground() {
        guard !cursorInBgEnabled else { return }
        typealias ConnID = Int32
        typealias SetPropFn = @convention(c) (ConnID, ConnID, CFString, CFBoolean) -> Int32
        typealias DefaultConnFn = @convention(c) () -> ConnID
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        defer { dlclose(handle) }
        guard
            let setSym = dlsym(handle, "CGSSetConnectionProperty"),
            let defSym = dlsym(handle, "_CGSDefaultConnection")
        else { return }
        let setProp = unsafeBitCast(setSym, to: SetPropFn.self)
        let defConn = unsafeBitCast(defSym, to: DefaultConnFn.self)
        let cid = defConn()
        _ = setProp(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        cursorInBgEnabled = true
    }

    private func forceHideSystemCursor() {
        enableCursorControlInBackground()
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
