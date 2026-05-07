import SwiftUI

struct StatusTab: View {
    @ObservedObject var status: BridgeStatusModel

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
                LabeledContent("Loopback :8787", value: status.portBound ? "bound" : "—")
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
