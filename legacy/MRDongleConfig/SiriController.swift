import AppKit
import ApplicationServices

/// Kích hoạt Siri khi remote gửi CFG VOICE 1.
/// Phase 1: mở Siri UI. Phase sau: virtual mic + PCM.
enum SiriController {
    static func ensureAccessibility(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt else { return false }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Mở Siri. Ưu tiên launch app; fallback hotkey Globe/Fn nếu user đã bật.
    @discardableResult
    static func activate() -> String {
        if NSWorkspace.shared.launchApplication("Siri") {
            return "Đã mở Siri"
        }
        // Fallback: thử phím tắt phổ biến (Globe = keyCode 63 trên một số layout)
        _ = ensureAccessibility(prompt: true)
        postKey(63, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postKey(63, down: false)
        }
        return "Đã gửi hotkey Siri (kiểm tra System Settings → Siri)"
    }

    private static func postKey(_ keyCode: CGKeyCode, down: Bool) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        ev.post(tap: .cghidEventTap)
    }
}
