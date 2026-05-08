import SwiftUI
import AppKit
import BridgeConfig
import BridgeAuth

/// Read-only display of the bridge's Tailscale state. Mirrors the
/// `icloud-bridge tailscale status` CLI: configuration values from
/// `config.toml`, probe state from the `tailscale` CLI (binary path,
/// tailnet IPv4, self-peer whois), and a derived listener-readiness line.
struct TailscaleTab: View {
    @ObservedObject var status: BridgeStatusModel

    // Config snapshot.
    @State private var config: Config = Config()

    // Probe results.
    @State private var cliPath: String? = nil
    @State private var cliError: String? = nil
    @State private var tailnetIP: String? = nil
    @State private var tailnetIPError: String? = nil
    @State private var selfPeer: TailscaleProbe.PeerInfo? = nil

    @State private var loadError: String? = nil
    @State private var loading: Bool = false

    var body: some View {
        Form {
            configSection
            probeSection
            listenerSection
            allowlistSection
            referenceSection
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadAll() }
    }

    // MARK: - sections

    private var configSection: some View {
        Section("Configuration") {
            LabeledContent("Enabled", value: config.tailscale.enabled ? "yes" : "no")
            LabeledContent("Port", value: "\(config.tailscale.port)")
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
            HStack {
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await loadAll() }
                }
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
            if config.tailscale.enabled, let ip = tailnetIP {
                HStack {
                    Text("Bound at")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ip):\(config.tailscale.port)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var listenerStatusView: some View {
        if !config.tailscale.enabled {
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

    private var allowlistSection: some View {
        Section("Allowlist") {
            allowlistRow(
                label: "Allowed peers",
                values: config.tailscale.allowedPeers,
                emptyHint: "Open — any tailnet peer with a valid bearer token"
            )
            allowlistRow(
                label: "Allowed users",
                values: config.tailscale.allowedUsers,
                emptyHint: "Open"
            )
            if config.tailscale.enabled,
               config.tailscale.allowedPeers.isEmpty,
               config.tailscale.allowedUsers.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    iconBadge(systemName: "exclamationmark.triangle.fill", color: .orange)
                    Text("Both lists are empty. The bridge will accept any tailnet peer that presents a valid bearer token. Set `allowed_peers` and/or `allowed_users` in config.toml to restrict.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var referenceSection: some View {
        Section("Reference") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inspect via CLI")
                    .font(.callout.bold())
                Text("icloud-bridge tailscale status")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("icloud-bridge tailscale whois <ip>")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("Edit `\(BridgePaths.configFile.path)` and bounce the daemon (Status tab → Restart) for changes to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - row helpers

    @ViewBuilder
    private func allowlistRow(label: String, values: [String], emptyHint: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if values.isEmpty {
                Text(emptyHint).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(values.joined(separator: ", "))
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private func iconBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(color)
    }

    // MARK: - load

    private func loadAll() async {
        loading = true
        defer { loading = false }
        loadError = nil

        // Config — synchronous file read; small, no spinner needed.
        do {
            self.config = try ConfigStore().load()
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
}
