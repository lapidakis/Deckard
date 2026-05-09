import SwiftUI

struct StatusTab: View {
    @ObservedObject var status: BridgeStatusModel
    @ObservedObject var onboarding: OnboardingState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Daemon") {
                LabeledContent("State") {
                    HStack {
                        Circle()
                            .fill(status.isRunning ? Color.green : Color.red)
                            .frame(width: 9, height: 9)
                        Text(status.isRunning ? "Running" : "Stopped")
                    }
                }
                LabeledContent("PID", value: status.pid.map { "\($0)" } ?? "—")
                LabeledContent("Loopback :\(status.loopbackPort)", value: status.portBound ? "bound" : "—")
            }

            Section("Audit") {
                LabeledContent("Entries", value: "\(status.auditEntryCount)")
                LabeledContent("Newest", value: status.auditNewestTs ?? "—")
            }

            Section("Control") {
                HStack {
                    Button("Start") { Task { await status.start() } }
                        .disabled(status.isRunning)
                    Button("Stop") { Task { await status.stop() } }
                        .disabled(!status.isRunning)
                    Button("Restart") { Task { await status.restart() } }
                    Spacer()
                    Button("Refresh") { Task { await status.refresh() } }
                }
            }

            Section("Setup") {
                HStack {
                    Text("Walk through the first-run setup again — daemon, token, permissions, client connection details.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Onboarding…") {
                        onboarding.forceOpen()
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }

            if let err = status.lastError {
                Section("Last error") {
                    Text(err).foregroundStyle(.red).font(.callout.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
