import SwiftUI
import AppKit

@main
struct MagicRemoteBLEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        /* `Window`, not `WindowGroup`: a group is a multi-window scene, so `openWindow`
           spawns a new window on every call instead of focusing the existing one. */
        Window("MagicRemoteBLE", id: AppWindowID.main) {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: MenuBarStatusSymbol.systemImage(for: model.host.phase))
                if let battery = model.host.batteryLevel {
                    Text("\(battery)%")
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
            .help("MagicRemoteBLE")
        }
        .menuBarExtraStyle(.menu)
    }
}
