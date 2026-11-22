import SwiftUI
import AppKit
import BridgeConfig

/// The search trade-off: grant the daemon Full Disk Access for fast, complete
/// mail search by reading Mail's own database, or grant nothing and accept
/// slower, partial results.
///
/// The app cannot test the daemon's grant itself (privacy grants are per
/// process), so it shows what the daemon reported at its last start.
@MainActor
final class SearchAccessModel: ObservableObject {
    @Published var useSpotlight = false
    @Published var daemonStatus: DaemonStatus?
    @Published var daemonBinaryPath: String?
    @Published var needsRestart = false
    @Published var error: String?

    private let store = ConfigStore()

    /// True when the reported status is from the daemon that is running now.
    func statusIsCurrent(pid: Int32?) -> Bool {
        guard let pid, let daemonStatus else { return false }
        return daemonStatus.pid == pid
    }

    func load() {
        if let cfg = try? store.loadOrInit() { useSpotlight = cfg.search.fastSearch }
        daemonStatus = DaemonStatus.read()
        daemonBinaryPath = Self.launchAgentBinaryPath()
    }

    func choose(spotlight: Bool) {
        do {
            var cfg = try store.loadOrInit()
            guard cfg.search.fastSearch != spotlight else { return }
            cfg.search.fastSearch = spotlight
            try store.write(cfg)
            useSpotlight = spotlight
            needsRestart = true
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    /// The binary launchd runs: the thing that must be added to the Full
    /// Disk Access list.
    static func launchAgentBinaryPath() -> String? {
        let plist = URL(fileURLWithPath: OnboardingState.launchAgentPlistPath)
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = object["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }
}

struct SearchAccessView: View {
    @ObservedObject var model: SearchAccessModel
    @ObservedObject var status: BridgeStatusModel

    private var granted: Bool {
        model.statusIsCurrent(pid: status.pid.map { Int32($0) }) && model.daemonStatus?.fullDiskAccess == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            option(
                selected: !model.useSpotlight,
                title: "Standard search",
                detail: "No extra permission. Searching mail by subject or sender takes a few seconds. Searching message text is slower, only covers the last 30 days unless a date is given, and can return partial results."
            ) { model.choose(spotlight: false) }

            option(
                selected: model.useSpotlight,
                title: "Fast, complete search",
                detail: "Reads Mail's own message database and message files directly. Finding mail by subject, sender or date is instant, message text is searched across all your mail, and Deckard keeps no copy. Requires Full Disk Access for the Deckard daemon."
            ) { model.choose(spotlight: true) }

            if model.useSpotlight { fullDiskAccessBox }

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if model.needsRestart {
                HStack {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Text("Restart the daemon to apply.")
                    Spacer()
                    Button("Restart now") {
                        Task {
                            await status.restart()
                            model.needsRestart = false
                            // Give the new daemon a moment to write its status.
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            model.load()
                        }
                    }
                }
                .font(.callout)
            }
        }
        .task { model.load() }
    }

    private var fullDiskAccessBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(granted ? .green : .orange)
                    Text(granted ? "The daemon has Full Disk Access." : "The daemon does not have Full Disk Access yet.")
                        .font(.callout.bold())
                }
                Text("Full Disk Access is broad: it lets the daemon read other protected data on this Mac too, such as Messages and Safari history. Deckard only uses it to read Mail's message database and message files. Until it is granted, standard search is used.")
                    .font(.caption).foregroundStyle(.secondary)

                if !granted {
                    Text("1. Open Full Disk Access.  2. Click +, then add the daemon shown below (or drag it into the list).  3. Restart the daemon.")
                        .font(.caption)
                    if let path = model.daemonBinaryPath {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    } else {
                        Text("The daemon is not installed yet; finish the Daemon step first.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Open Full Disk Access") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        if let path = model.daemonBinaryPath {
                            Button("Show daemon in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                        Button("Restart daemon and recheck") {
                            Task {
                                await status.restart()
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                model.load()
                                model.needsRestart = false
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(6)
        }
    }

    private func option(selected: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Settings home for the same choice onboarding shows.
struct SearchAccessTab: View {
    @ObservedObject var status: BridgeStatusModel
    @StateObject private var model = SearchAccessModel()

    var body: some View {
        ScrollView { SearchAccessView(model: model, status: status).padding(16) }
    }
}
