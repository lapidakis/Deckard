import SwiftUI

@main
struct DeckardUI: App {
    @StateObject private var status = BridgeStatusModel()
    @StateObject private var onboarding = OnboardingState()

    var body: some Scene {
        // Menubar item — compact status + control buttons + link to Settings.
        MenuBarExtra {
            MenuBarContent(status: status, onboarding: onboarding)
        } label: {
            // The label is rendered immediately on launch (the icon goes up
            // in the menubar before the user clicks anything), so this is
            // where we hang the "auto-open onboarding on first launch"
            // trigger via OnboardingLauncher's `.task`.
            OnboardingLauncher(
                onboarding: onboarding,
                icon: status.isRunning ? "icloud.fill" : "icloud.slash.fill"
            )
        }
        .menuBarExtraStyle(.window)

        // Settings window — full multi-tab UI for detailed config.
        Settings {
            SettingsView(status: status, onboarding: onboarding)
        }

        // Onboarding window — opened by OnboardingLauncher on first launch
        // and by the "Show Onboarding…" button in the Status tab.
        Window("Welcome to Deckard", id: "onboarding") {
            OnboardingView(status: status, onboarding: onboarding)
        }
        .windowResizability(.contentSize)
    }
}

/// Renders the menubar icon AND owns the cold-launch hook that opens
/// the onboarding window. Lives in a sub-view so it can use
/// `@Environment(\.openWindow)` (only available inside View bodies, not
/// the App struct itself).
private struct OnboardingLauncher: View {
    @ObservedObject var onboarding: OnboardingState
    let icon: String
    @Environment(\.openWindow) private var openWindow
    @State private var attempted = false

    var body: some View {
        Image(systemName: icon)
            .task {
                guard !attempted else { return }
                attempted = true
                if OnboardingState.shouldAutoOpenAtLaunch() {
                    // Small settle delay so the App scene has finished
                    // mounting before we try to surface a window — without
                    // it the openWindow call sometimes no-ops on cold launch.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
