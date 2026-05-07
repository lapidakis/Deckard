import SwiftUI

@main
struct iCloudBridgeUI: App {
    @StateObject private var status = BridgeStatusModel()

    var body: some Scene {
        // Menubar item — compact status + control buttons + link to Settings.
        MenuBarExtra {
            MenuBarContent(status: status)
        } label: {
            // Cloud icon turns red when daemon isn't running, green otherwise.
            // System symbols give the native look without bundling our own.
            Image(systemName: status.isRunning ? "icloud.fill" : "icloud.slash.fill")
        }
        .menuBarExtraStyle(.window)

        // Settings window — full multi-tab UI for detailed config.
        Settings {
            SettingsView(status: status)
        }
    }
}
