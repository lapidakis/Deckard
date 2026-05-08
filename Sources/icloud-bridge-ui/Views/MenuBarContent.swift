import SwiftUI

/// Compact view shown when the user clicks the menubar icon. Status summary
/// + control buttons + link into the Settings window.
struct MenuBarContent: View {
    @ObservedObject var status: BridgeStatusModel
    @ObservedObject var onboarding: OnboardingState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(status.isRunning ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(status.isRunning ? "Running" : "Stopped")
                    .font(.headline)
                Spacer()
                if status.refreshing {
                    ProgressView().controlSize(.small)
                }
            }

            if let pid = status.pid {
                LabelRow(name: "PID", value: "\(pid)")
            }
            LabelRow(name: "Port 8787", value: status.portBound ? "bound" : "—")
            LabelRow(name: "Audit", value: status.auditEntryCount > 0
                ? "\(status.auditEntryCount) entries"
                : "no entries")

            if let err = status.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Start") {
                    Task { await status.start() }
                }
                .disabled(status.isRunning)

                Button("Stop") {
                    Task { await status.stop() }
                }
                .disabled(!status.isRunning)

                Button("Restart") {
                    Task { await status.restart() }
                }
            }

            HStack {
                Button("Open Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Refresh") {
                    Task { await status.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            Button("Show Onboarding…") {
                onboarding.forceOpen()
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Divider()

            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

private struct LabelRow: View {
    let name: String
    let value: String
    var body: some View {
        HStack {
            Text(name).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}
