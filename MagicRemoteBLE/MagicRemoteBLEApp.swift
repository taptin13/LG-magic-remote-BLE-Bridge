import SwiftUI
import AppKit

@main
struct MagicRemoteBLEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: AppWindowID.main) {
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
            Label("MagicRemoteBLE", systemImage: MenuBarStatusSymbol.systemImage(for: model.host.phase))
        }
        .menuBarExtraStyle(.menu)
    }
}
