import SwiftUI
import BridgeConfig

/// Read-only display of the current ACL (global + profiles). Editing lands
/// in the next pass — for now, edit `config.toml` directly and bounce the
/// daemon (or use `icloud-bridge` CLI).
struct ACLTab: View {
    struct ToolRow: Identifiable, Hashable {
        var id: String { tool }
        let tool: String
        let decision: ACLDecision
    }

    @State private var config: Config = Config()
    @State private var loadError: String? = nil
    @State private var selectedProfile: String = "<global>"

    private var profileNames: [String] {
        ["<global>"] + config.acl.profiles.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Access Control").font(.title3.bold())
                Spacer()
                Picker("Profile", selection: $selectedProfile) {
                    ForEach(profileNames, id: \.self) { p in Text(p).tag(p) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                Button("Reload") { load() }
            }

            if let err = loadError {
                Text(err).foregroundStyle(.red)
            }

            HStack {
                Text("Default")
                    .foregroundStyle(.secondary)
                Spacer()
                DecisionBadge(decision: defaultDecision)
            }

            Divider()

            Table(toolEntries) {
                TableColumn("Tool") { Text($0.tool) }
                TableColumn("Decision") { row in
                    DecisionBadge(decision: row.decision)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Editing").font(.callout.bold())
                Text("Edit `\(BridgePaths.configFile.path)` directly; bounce the daemon afterward (Status tab → Restart). Inline editing UI is planned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(BridgePaths.configFile.path).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .padding()
        .task { load() }
    }

    private var defaultDecision: ACLDecision {
        if selectedProfile == "<global>" { return config.acl.default }
        return config.acl.profiles[selectedProfile]?.default ?? config.acl.default
    }

    private var toolEntries: [ToolRow] {
        let map: [String: ACLDecision]
        if selectedProfile == "<global>" {
            map = config.acl.tools
        } else {
            map = config.acl.profiles[selectedProfile]?.tools ?? [:]
        }
        return map.map { ToolRow(tool: $0.key, decision: $0.value) }
            .sorted { $0.tool < $1.tool }
    }

    private func load() {
        do {
            let store = ConfigStore()
            self.config = try store.load()
            self.loadError = nil
        } catch {
            self.loadError = "Failed to load config: \(error)"
        }
    }
}

private struct DecisionBadge: View {
    let decision: ACLDecision
    var body: some View {
        Text(decision.rawValue.uppercased())
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch decision {
        case .allow:   return .green
        case .deny:    return .red
        case .approve: return .orange
        }
    }
}
