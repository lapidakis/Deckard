import SwiftUI

/// Multi-tab Settings window. Native macOS look via `Form` + `TabView`
/// matches the System Settings style.
struct SettingsView: View {
    @ObservedObject var status: BridgeStatusModel

    var body: some View {
        TabView {
            StatusTab(status: status)
                .tabItem { Label("Status", systemImage: "checkmark.circle") }

            TokensTab()
                .tabItem { Label("Tokens", systemImage: "key.fill") }

            ACLTab()
                .tabItem { Label("ACL", systemImage: "lock.shield") }

            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised.fill") }

            LogsTab()
                .tabItem { Label("Logs", systemImage: "doc.text") }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}
