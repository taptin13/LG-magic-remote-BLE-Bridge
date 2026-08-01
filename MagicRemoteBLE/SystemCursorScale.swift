import AppKit
import Darwin

/// Scales the real system cursor through WindowServer.
///
/// Preferred over an overlay panel: the scaled cursor is the actual pointer, so it
/// survives the Dock, fullscreen video, rapid clicks and cursor-rect changes made by
/// other apps — none of which we can win by hiding the cursor and drawing our own.
///
/// Uses private SkyLight symbols; every entry point is probed with `dlsym` and the
/// caller falls back to the overlay when unavailable.
final class SystemCursorScale {
    private typealias ConnID = Int32
    private typealias SetScaleFn = @convention(c) (ConnID, Float) -> Int32
    private typealias GetScaleFn = @convention(c) (ConnID, UnsafeMutablePointer<Float>) -> Int32
    private typealias MainConnFn = @convention(c) () -> ConnID

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    private var handle: UnsafeMutableRawPointer?
    private var setScaleFn: SetScaleFn?
    private var getScaleFn: GetScaleFn?
    private var connection: ConnID = 0

    /// Scale captured at init (user's own size) — always restore to this.
    private var baseline: Float = 1.0
    private var appliedScale: Float?

    let isAvailable: Bool

    init() {
        guard let h = dlopen(Self.frameworkPath, RTLD_LAZY),
              let setSym = dlsym(h, "CGSSetCursorScale"),
              let getSym = dlsym(h, "CGSGetCursorScale"),
              let connSym = dlsym(h, "SLSMainConnectionID")
        else {
            isAvailable = false
            NSLog("SystemCursorScale: SkyLight cursor scaling unavailable — overlay fallback")
            return
        }
        handle = h
        setScaleFn = unsafeBitCast(setSym, to: SetScaleFn.self)
        getScaleFn = unsafeBitCast(getSym, to: GetScaleFn.self)
        connection = unsafeBitCast(connSym, to: MainConnFn.self)()

        var probe: Float = 0
        guard let getScaleFn, getScaleFn(connection, &probe) == 0 else {
            isAvailable = false
            NSLog("SystemCursorScale: CGSGetCursorScale rejected — overlay fallback")
            return
        }
        /* If a previous crash left the pointer oversized, treat 1.0 as baseline
           so "restore" actually returns to the normal system size. */
        baseline = (probe >= 0.99 && probe <= 1.05) ? probe : 1.0
        if abs(probe - baseline) > 0.05 {
            _ = setScaleFn?(connection, baseline)
        }
        isAvailable = true
    }

    private func refreshConnection() {
        guard let connSym = dlsym(handle, "SLSMainConnectionID") else { return }
        connection = unsafeBitCast(connSym, to: MainConnFn.self)()
    }

    private func currentScale() -> Float? {
        guard let getScaleFn else { return nil }
        var v: Float = 0
        guard getScaleFn(connection, &v) == 0 else { return nil }
        return v
    }

    /// Apply `scale` (clamped). Refreshes the SkyLight connection each time —
    /// a stale connection id silently no-ops after display sleep / remote flaps.
    @discardableResult
    func apply(_ scale: Float) -> Bool {
        guard isAvailable, let setScaleFn else { return false }
        refreshConnection()
        let target = min(max(scale, 1.0), 4.0)
        if let appliedScale, abs(appliedScale - target) < 0.01,
           let cur = currentScale(), abs(cur - target) < 0.05
        {
            return true
        }
        guard setScaleFn(connection, target) == 0 else { return false }
        appliedScale = target
        return true
    }

    /// Put the pointer back to the baseline captured at launch.
    func restore() {
        guard isAvailable, let setScaleFn else { return }
        guard appliedScale != nil || (currentScale().map { abs($0 - baseline) > 0.05 } ?? false) else {
            appliedScale = nil
            return
        }
        refreshConnection()
        _ = setScaleFn(connection, baseline)
        appliedScale = nil
    }

    var isScaled: Bool {
        if appliedScale != nil { return true }
        guard let cur = currentScale() else { return false }
        return abs(cur - baseline) > 0.05
    }

    deinit {
        restore()
    }
}
