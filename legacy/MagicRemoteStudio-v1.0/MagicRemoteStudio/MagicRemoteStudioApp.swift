import SwiftUI

@main
struct MagicRemoteStudioApp: App {
    @StateObject private var studio = StudioModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(studio)
                .frame(minWidth: 1180, minHeight: 720)
        }
    }
}
