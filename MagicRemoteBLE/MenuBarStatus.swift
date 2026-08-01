import SwiftUI
import AppKit

enum AppWindowID {
    static let main = "main"
}

extension Notification.Name {
    static let showMagicRemoteMainWindow = Notification.Name("showMagicRemoteMainWindow")
}

@MainActor
enum DockVisibility {
    /// Hide Dock icon when no titled main window remains (menu bar stays).
    static func hideIfNoMainWindows() {
        let hasMain = NSApp.windows.contains { isMainUIWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if !hasMain {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func revealForMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func isMainUIWindow(_ window: NSWindow) -> Bool {
        if window is NSPanel { return false }
        let typeName = String(describing: type(of: window))
        if typeName.contains("StatusBar") || typeName.contains("MenuBarExtra") { return false }
        guard window.styleMask.contains(.titled) else { return false }
        return true
    }

    static func orderFrontMainWindows() {
        for window in NSApp.windows where isMainUIWindow(window) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// True when a main window already exists and could be brought forward.
    @discardableResult
    static func revealExistingMainWindow() -> Bool {
        let windows = NSApp.windows.filter { isMainUIWindow($0) }
        guard !windows.isEmpty else { return false }
        revealForMainWindow()
        for window in windows { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated {
            /* The menu-bar observer only exists while the menu is open, so reuse the
               retained window directly and fall back to the notification. */
            if !DockVisibility.revealExistingMainWindow() {
                NotificationCenter.default.post(name: .showMagicRemoteMainWindow, object: nil)
            }
        }
        return true
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        Task { @MainActor in
            guard DockVisibility.isMainUIWindow(window) else { return }
            let otherMainOpen = NSApp.windows.contains {
                $0 !== window
                    && DockVisibility.isMainUIWindow($0)
                    && ($0.isVisible || $0.isMiniaturized)
            }
            if !otherMainOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Menu bar (macOS “taskbar”) status item — connection state + quick actions.
struct MenuBarStatusView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(statusTitle)
                .font(.headline)
            Text(statusSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)

        Divider()

        Button("Show Window") {
            showMainWindow()
        }
        .keyboardShortcut("o")
        .onReceive(NotificationCenter.default.publisher(for: .showMagicRemoteMainWindow)) { _ in
            showMainWindow()
        }

        Button(model.host.phase == .ready ? "Disconnect" : "Reconnect") {
            if model.host.phase == .ready {
                model.host.disconnect(userInitiated: true)
            } else {
                model.host.reconnect()
            }
        }

        Toggle("Map to Mac input", isOn: Binding(
            get: { model.mapper.wantsEnabled },
            set: {
                model.mapper.setEnabled($0)
                model.syncPointerOverlay()
            }
        ))

        Toggle("Mouse mode", isOn: Binding(
            get: { model.mapper.mouseMode },
            set: { model.mapper.setMouseMode($0) }
        ))
        .disabled(!model.mapper.wantsEnabled)

        Divider()

        Button("Quit MagicRemoteBLE") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusTitle: String {
        switch model.host.phase {
        case .ready: return "Bridge Ready"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .discovering: return "Discovering…"
        case .poweredOff: return "Bluetooth Off"
        case .failed: return "Bridge Failed"
        case .idle: return "Idle"
        }
    }

    private var statusSubtitle: String {
        let remote = model.host.remoteStatus
        let map = model.mapper.wantsEnabled
            ? (model.mapper.enabled
               ? (model.mapper.mouseMode ? "Mouse ON" : "Map ON")
               : "Map (needs Accessibility)")
            : "Map OFF"
        return "Remote: \(remote) · \(map)"
    }

    private func showMainWindow() {
        DockVisibility.revealForMainWindow()
        if !DockVisibility.revealExistingMainWindow() {
            openWindow(id: AppWindowID.main)
            DockVisibility.orderFrontMainWindows()
        }
    }
}

enum MenuBarStatusSymbol {
    static func systemImage(for phase: BLEBridgeHost.Phase) -> String {
        switch phase {
        case .ready:
            return "antenna.radiowaves.left.and.right"
        case .scanning, .connecting, .discovering:
            return "dot.radiowaves.left.and.right"
        case .poweredOff, .failed:
            return "antenna.radiowaves.left.and.right.slash"
        case .idle:
            return "av.remote"
        }
    }
}
