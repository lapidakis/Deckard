import SwiftUI
import AppKit
import BridgeConfig
import BridgeAuth

/// Editable settings for the Tailscale listener.
///
/// Two fields (Enabled, Port) and a Save button that writes
/// `~/Library/Application Support/Deckard/config.toml` and offers a
/// daemon restart so the listener picks up the change. Probe section
/// underneath surfaces tailscaled state (CLI presence, tailnet IPv4,
/// self-whois) so the user can confirm the listener will actually bind.
///
/// Peer ACLs are intentionally not configurable here — Deckard delegates
/// that to tailscaled. If a peer can reach the listener, your tailnet
/// policy has already permitted it; bearer auth still applies on top.
struct TailscaleTab: View {
    @ObservedObject var status: BridgeStatusModel

    // Loaded snapshot — used to detect "dirty" state vs. edits below.
    @State private var loaded: Config = Config()

    // Editable fields. Mirror loaded values on initial load and after Save.
    @State private var enabled: Bool = false
    @State private var port: Int = 8787

    // Probe results.
    @State private var cliPath: String? = nil
    @State private var cliError: String? = nil
    @State private var tailnetIP: String? = nil
    @State private var tailnetIPError: String? = nil
    @State private var selfPeer: TailscaleProbe.PeerInfo? = nil

    @State private var loadError: String? = nil
    @State private var saveError: String? = nil
    @State private var loading: Bool = false
    @State private var saving: Bool = false
    @State private var savedNeedsRestart: Bool = false

    private var isDirty: Bool {
        enabled != loaded.tailscale.enabled || port != loaded.tailscale.port
    }

    var body: some View {
        Form {
            settingsSection
            probeSection
            listenerSection
            referenceSection
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadAll() }
    }

    // MARK: - sections

    private var settingsSection: some View {
        Section("Settings") {
            Toggle("Enable tailnet listener", isOn: $enabled)
                .help("When on, the daemon binds an HTTP listener on this Mac's tailnet IPv4 in addition to 127.0.0.1.")

            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Stepper("", value: $port, in: 1...65535).labelsHidden()
            }

            HStack(alignment: .top, spacing: 8) {
                iconBadge(systemName: "lock.shield", color: .secondary)
                Text("Peer ACLs are delegated to tailscaled — set them in your Tailscale admin console. Deckard still requires a bearer token over the tailnet listener.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Source")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(BridgePaths.configFile.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if let err = saveError {
                HStack(alignment: .top, spacing: 8) {
                    iconBadge(systemName: "xmark.octagon.fill", color: .red)
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            if savedNeedsRestart {
                HStack(alignment: .top, spacing: 8) {
                    iconBadge(systemName: "info.circle.fill", color: .accentColor)
                    Text("Saved. Restart the daemon for the listener change to take effect.")
                        .font(.caption)
                    Spacer()
                    Button("Restart daemon") {
                        Task {
                            await status.restart()
                            savedNeedsRestart = false
                            await loadAll()
                        }
                    }
                    .controlSize(.small)
                }
            }

            HStack {
                if loading || saving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Revert") { revert() }
                    .disabled(!isDirty || saving)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || saving)
            }
        }
    }

    private var probeSection: some View {
        Section("Probe") {
            HStack(alignment: .firstTextBaseline) {
                Text("Tailscale CLI")
                    .foregroundStyle(.secondary)
                Spacer()
                if let path = cliPath {
                    iconBadge(systemName: "checkmark.circle.fill", color: .green)
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                } else if let err = cliError {
                    iconBadge(systemName: "xmark.circle.fill", color: .red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Tailnet IPv4")
                    .foregroundStyle(.secondary)
                Spacer()
                if let ip = tailnetIP {
                    iconBadge(systemName: "checkmark.circle.fill", color: .green)
                    Text(ip)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else if let err = tailnetIPError {
                    iconBadge(systemName: "exclamationmark.triangle.fill", color: .orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            if let peer = selfPeer {
                LabeledContent("Hostname", value: peer.hostname ?? "—")
                LabeledContent("User", value: peer.user ?? "—")
            }

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await loadAll() }
                }
                .controlSize(.small)
            }
        }
    }

    private var listenerSection: some View {
        Section("Listener") {
            HStack {
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                listenerStatusView
            }
            if loaded.tailscale.enabled, let ip = tailnetIP {
                HStack {
                    Text("Bound at")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ip):\(loaded.tailscale.port)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var listenerStatusView: some View {
        if !loaded.tailscale.enabled {
            HStack(spacing: 6) {
                iconBadge(systemName: "minus.circle", color: .secondary)
                Text("Disabled in config")
            }
        } else if cliPath == nil {
            HStack(spacing: 6) {
                iconBadge(systemName: "xmark.circle.fill", color: .red)
                Text("Tailscale CLI not installed")
            }
        } else if tailnetIP == nil {
            HStack(spacing: 6) {
                iconBadge(systemName: "exclamationmark.triangle.fill", color: .orange)
                Text("Tailscale up but no tailnet IP")
            }
        } else if !status.isRunning {
            HStack(spacing: 6) {
                iconBadge(systemName: "exclamationmark.triangle.fill", color: .orange)
                Text("Daemon stopped — listener not bound")
            }
        } else {
            // Daemon running + Tailscale up + IP resolved + config enabled.
            // BridgeServer binds the tailnet listener at startup; we don't
            // probe the socket because doing so requires either lsof on a
            // privileged TCP table view or a connect attempt that would
            // count as a (denied) request in the audit log.
            HStack(spacing: 6) {
                iconBadge(systemName: "checkmark.circle.fill", color: .green)
                Text("Listening")
            }
        }
    }

    private var referenceSection: some View {
        Section("Reference") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inspect via CLI")
                    .font(.callout.bold())
                Text("deckard tailscale status")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("deckard tailscale whois <ip>")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - helpers

    private func iconBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(color)
    }

    private func revert() {
        enabled = loaded.tailscale.enabled
        port = loaded.tailscale.port
        saveError = nil
    }

    // MARK: - load + save

    private func loadAll() async {
        loading = true
        defer { loading = false }
        loadError = nil

        // Config — synchronous file read; small, no spinner needed.
        do {
            let cfg = try ConfigStore().load()
            self.loaded = cfg
            self.enabled = cfg.tailscale.enabled
            self.port = cfg.tailscale.port
        } catch {
            loadError = "config: \(error)"
        }

        // Probe — actor methods. Don't fail the whole tab if probe errors;
        // each result column has its own error slot. Default logger label
        // (bridge.tailscale) is fine; the UI doesn't write to log files.
        let probe = TailscaleProbe()

        do {
            let path = try await probe.findBinary()
            self.cliPath = path
            self.cliError = nil
        } catch {
            self.cliPath = nil
            self.cliError = "\(error)"
        }

        // Skip the rest of the probe if the CLI isn't there — the calls
        // would just fail the same way and clutter the UI with redundant
        // "not installed" errors.
        guard cliPath != nil else {
            self.tailnetIP = nil
            self.tailnetIPError = nil
            self.selfPeer = nil
            return
        }

        do {
            let ip = try await probe.tailnetIPv4()
            self.tailnetIP = ip
            self.tailnetIPError = nil
            // Best-effort whois on self IP — surfaces the hostname/user
            // the bridge would report for incoming requests from this
            // Mac. Useful for "what does my own peer label look like?".
            self.selfPeer = await probe.whois(remoteIP: ip)
        } catch {
            self.tailnetIP = nil
            self.tailnetIPError = "\(error)"
            self.selfPeer = nil
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        saveError = nil

        guard (1...65535).contains(port) else {
            saveError = "Port must be between 1 and 65535"
            return
        }

        do {
            let store = ConfigStore()
            // Re-read from disk so we don't clobber unrelated edits the
            // user (or another tool) made between our load and save.
            var cfg = try store.load()
            cfg.tailscale.enabled = enabled
            cfg.tailscale.port = port
            try store.write(cfg)
            self.loaded = cfg
            self.savedNeedsRestart = true
        } catch {
            saveError = "\(error)"
        }
    }
}
