import SwiftUI

@main
struct OpenClawApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("API Keys…") {
                    NotificationCenter.default.post(name: .showAPIKeyManager, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let showAPIKeyManager = Notification.Name("showAPIKeyManager")
}
