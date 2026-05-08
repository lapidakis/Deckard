import SwiftUI
import BridgeAuth

/// Read-only list of tokens. Mutations (add/revoke/rotate) handled via the
/// `deckard auth` CLI for v0.1; UI-side editing lands in the next pass.
struct TokensTab: View {
    struct Row: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let profile: String
        let created: String
        let description: String
    }

    @State private var entries: [Row] = []
    @State private var loadError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tokens").font(.title3.bold())
                Spacer()
                Button("Reload") { Task { await load() } }
            }

            if let err = loadError {
                Text(err).foregroundStyle(.red)
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "No tokens",
                    systemImage: "key.slash",
                    description: Text("Run `deckard auth add <label>` to create one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(entries) {
                    TableColumn("Label", value: \.label)
                    TableColumn("Profile") { row in
                        Text(row.profile)
                            .foregroundStyle(row.profile == "<global>" ? .secondary : .primary)
                    }
                    TableColumn("Created") { row in
                        Text(row.created).font(.caption.monospacedDigit())
                    }
                    TableColumn("Description") { row in
                        Text(row.description).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Token operations").font(.callout.bold())
                Text("Manage tokens via the CLI for now — UI editing lands in the next pass.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("deckard auth add <label> --profile <name> --description \"…\"")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("deckard auth list / show / rotate / revoke")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        do {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let raw = await registry.allEntries()
            self.entries = raw.map { (label, entry) in
                Row(
                    label: label,
                    profile: entry.profile ?? "<global>",
                    created: entry.created,
                    description: entry.description
                )
            }
            self.loadError = nil
        } catch {
            self.loadError = "Failed to load tokens: \(error)"
        }
    }
}
