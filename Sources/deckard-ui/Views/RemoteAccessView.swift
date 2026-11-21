import SwiftUI
import BridgeAuth
import BridgeConfig

/// State and actions for choosing how agents reach Deckard from other
/// machines: nothing (this Mac only), Tailscale, Cloudflare, or both.
///
/// Used by the onboarding "Remote access" step and the Settings tab, so the
/// two can never drift. Every action re-reads config.toml before writing so
/// edits made elsewhere are not clobbered.
@MainActor
final class RemoteAccessModel: ObservableObject {
    // Tailscale
    @Published var tailscaleEnabled = false
    @Published var tailscaleCLI: String?
    @Published var tailnetIP: String?

    // Cloudflare
    @Published var cloudflareEnabled = false
    @Published var cloudflaredPath: String?
    @Published var cloudflareSignedIn = false
    @Published var hostname = ""
    @Published var tunnelName = "deckard"
    @Published var tunnelReady = false
    @Published var teamDomain = ""
    @Published var audience = ""
    @Published var identityEmail = ""
    @Published var identityProfile = ""
    @Published var profiles: [String] = []
    @Published var bearerTokens = true

    @Published var busy: String?
    @Published var error: String?
    @Published var needsRestart = false
    /// True until the Access details on screen match what is saved.
    @Published var needsAccessSave = true

    private let store = ConfigStore()

    var accessReady: Bool {
        !teamDomain.trimmed.isEmpty && !audience.trimmed.isEmpty
            && !identityEmail.trimmed.isEmpty && !identityProfile.isEmpty
    }

    func load() async {
        cloudflaredPath = CloudflareSetup.findBinary()
        cloudflareSignedIn = CloudflareSetup.isLoggedIn
        if let cfg = try? store.loadOrInit() {
            tailscaleEnabled = cfg.tailscale.enabled
            cloudflareEnabled = cfg.cloudflareTunnel.enabled
            bearerTokens = cfg.auth.bearerTokens
            profiles = cfg.acl.profiles.keys.sorted()
            if hostname.isEmpty { hostname = cfg.cloudflareAccess.publicHosts.first ?? "" }
            if teamDomain.isEmpty { teamDomain = cfg.cloudflareAccess.teamDomain }
            if audience.isEmpty { audience = cfg.cloudflareAccess.audiences.first ?? "" }
            if identityEmail.isEmpty, let first = cfg.cloudflareAccess.identities.sorted(by: { $0.key < $1.key }).first {
                identityEmail = first.key
                identityProfile = first.value
            }
            if identityProfile.isEmpty { identityProfile = profiles.first ?? "" }
            needsAccessSave = !(cfg.cloudflareAccess.enabled && !cfg.cloudflareAccess.identities.isEmpty)
            tunnelReady = cfg.cloudflareTunnel.enabled
                && FileManager.default.fileExists(atPath: CloudflareSetup.expand(cfg.cloudflareTunnel.configFile))
        }
        let probe = TailscaleProbe()
        tailscaleCLI = try? await probe.findBinary()
        tailnetIP = tailscaleCLI == nil ? nil : try? await probe.tailnetIPv4()
    }

    func setTailscale(_ on: Bool) {
        update("Saving") { cfg in cfg.tailscale.enabled = on }
        tailscaleEnabled = on
    }

    func signInToCloudflare() async {
        guard let binary = cloudflaredPath else { return }
        await run("Waiting for Cloudflare sign-in in your browser") {
            try await CloudflareSetup.login(binary: binary)
        }
        cloudflareSignedIn = CloudflareSetup.isLoggedIn
    }

    /// Creates (or reuses) the tunnel, writes its config, routes DNS, and
    /// turns on the daemon-managed connector.
    func createTunnel() async {
        guard let binary = cloudflaredPath else { return }
        let host = hostname.trimmed.lowercased()
        let name = tunnelName.trimmed.isEmpty ? "deckard" : tunnelName.trimmed
        guard CloudflareSetup.isValidHostname(host) else {
            error = CloudflareSetup.SetupError.invalidHostname(hostname).description
            return
        }
        await run("Creating tunnel and routing \(host)") {
            var cfg = try self.store.loadOrInit()
            let id = try await CloudflareSetup.ensureTunnel(named: name, binary: binary)
            try CloudflareSetup.writeIngressConfig(
                tunnelID: id, hostname: host, port: cfg.server.loopbackPort,
                to: URL(fileURLWithPath: CloudflareSetup.expand(cfg.cloudflareTunnel.configFile)))
            try await CloudflareSetup.routeDNS(tunnelName: name, hostname: host, binary: binary)
            // Re-read: the awaits above gave other writers a window.
            cfg = try self.store.loadOrInit()
            cfg.cloudflareTunnel.enabled = true
            if !cfg.cloudflareAccess.publicHosts.contains(host) { cfg.cloudflareAccess.publicHosts.append(host) }
            try self.store.write(cfg)
            self.tunnelReady = true
            self.cloudflareEnabled = true
            self.needsRestart = true
        }
    }

    /// Records who Cloudflare Access may let in and which profile they get.
    func saveAccess() {
        let email = identityEmail.trimmed
        let subject = email.contains("@") ? email.lowercased() : email
        update("Saving") { cfg in
            cfg.cloudflareAccess.teamDomain = self.teamDomain.trimmed
            let tag = self.audience.trimmed
            if !cfg.cloudflareAccess.audiences.contains(tag) { cfg.cloudflareAccess.audiences = [tag] }
            cfg.cloudflareAccess.identities[subject] = self.identityProfile
            cfg.cloudflareAccess.enabled = true
        }
    }

    func disableCloudflare() {
        update("Saving") { cfg in
            cfg.cloudflareTunnel.enabled = false
            cfg.cloudflareAccess.enabled = false
            // Never leave the daemon with no way to authenticate.
            cfg.auth.bearerTokens = true
        }
        cloudflareEnabled = false
        tunnelReady = false
        bearerTokens = true
    }

    func setBearerTokens(_ on: Bool) {
        update("Saving") { cfg in cfg.auth.bearerTokens = on || !cfg.cloudflareAccess.enabled }
        bearerTokens = on
    }

    private func update(_ label: String, _ change: (inout Config) -> Void) {
        do {
            var cfg = try store.loadOrInit()
            change(&cfg)
            try store.write(cfg)
            error = nil
            needsRestart = true
        } catch {
            self.error = "\(error)"
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) async {
        busy = label
        error = nil
        defer { busy = nil }
        do { try await work() } catch { self.error = "\(error)" }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The remote-access chooser. Each option is independent: enable neither,
/// either, or both.
struct RemoteAccessView: View {
    @ObservedObject var model: RemoteAccessModel
    @ObservedObject var status: BridgeStatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                localCard
                tailscaleCard
                cloudflareCard

                if let busy = model.busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.callout) }
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if model.needsRestart {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("Restart the daemon to apply these changes.")
                        Spacer()
                        Button("Restart now") {
                            Task { await status.restart(); model.needsRestart = false }
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.trailing, 4)
        }
        .task { await model.load() }
    }

    private var localCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac").font(.callout.bold())
                    Text("Always available. Agents on this Mac connect over loopback with a token, or run Deckard directly over stdio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private var tailscaleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { model.tailscaleEnabled }, set: { model.setTailscale($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tailscale").font(.callout.bold())
                        Text("Private access from your own devices. Traffic stays encrypted end to end inside your tailnet; agents still need a token.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.tailscaleEnabled || model.tailscaleCLI == nil {
                    Text(tailscaleDetail).font(.caption).foregroundStyle(model.tailnetIP == nil ? .orange : .secondary)
                }
            }
            .padding(6)
        }
    }

    private var tailscaleDetail: String {
        if model.tailscaleCLI == nil { return "Tailscale is not installed on this Mac. Install it and sign in first." }
        if let ip = model.tailnetIP { return "Tailnet address: \(ip)" }
        return "Tailscale is installed but not connected. Open Tailscale and sign in."
    }

    private var cloudflareCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { model.cloudflareEnabled },
                    set: { on in if on { model.cloudflareEnabled = true } else { model.disableCloudflare() } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloudflare").font(.callout.bold())
                        Text("A public HTTPS address with sign-in, for Claude and other hosted agents. Cloudflare can read the traffic it carries.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.cloudflareEnabled { cloudflareSetup }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var cloudflareSetup: some View {
        Divider()
        stepRow(1, done: model.cloudflaredPath != nil, title: "Install cloudflared") {
            if model.cloudflaredPath == nil {
                HStack {
                    Text("brew install cloudflared").font(.caption.monospaced()).textSelection(.enabled)
                    Button("Recheck") { Task { await model.load() } }.controlSize(.small)
                }
            }
        }
        stepRow(2, done: model.cloudflareSignedIn, title: "Sign in to Cloudflare") {
            if !model.cloudflareSignedIn {
                Button("Sign in…") { Task { await model.signInToCloudflare() } }
                    .controlSize(.small)
                    .disabled(model.cloudflaredPath == nil || model.busy != nil)
            }
        }
        stepRow(3, done: model.tunnelReady, title: "Create the tunnel") {
            HStack {
                TextField("deckard.example.com", text: $model.hostname)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Button(model.tunnelReady ? "Update" : "Create") { Task { await model.createTunnel() } }
                    .controlSize(.small)
                    .disabled(!model.cloudflareSignedIn || model.hostname.isEmpty || model.busy != nil)
            }
            Text("A hostname on a domain in your Cloudflare account. Only /mcp is forwarded to Deckard.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        stepRow(4, done: model.accessReady && !model.needsAccessSave, title: "Require sign-in (Cloudflare Access)") {
            Text("In Cloudflare: Zero Trust > Access controls > Applications, create a self-hosted application for the hostname, add an Allow policy for yourself, and turn on Managed OAuth. Then paste its details here.")
                .font(.caption2).foregroundStyle(.secondary)
            Link("Open Cloudflare Zero Trust", destination: URL(string: "https://one.dash.cloudflare.com/")!)
                .font(.caption)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Team domain").font(.caption)
                    TextField("myteam.cloudflareaccess.com", text: $model.teamDomain).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Audience tag").font(.caption)
                    TextField("AUD tag from the application", text: $model.audience).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Your sign-in email").font(.caption)
                    TextField("you@example.com", text: $model.identityEmail).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Permissions").font(.caption)
                    if model.profiles.isEmpty {
                        Text("No ACL profiles yet. Create one in the ACL tab first.").font(.caption).foregroundStyle(.orange)
                    } else {
                        Picker("", selection: $model.identityProfile) {
                            ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: 220)
                    }
                }
            }
            Button("Save sign-in settings") { model.saveAccess(); model.needsAccessSave = false }
                .controlSize(.small)
                .disabled(!model.accessReady)
        }
        if model.accessReady {
            Toggle("Also accept bearer tokens", isOn: Binding(get: { model.bearerTokens }, set: { model.setBearerTokens($0) }))
                .font(.caption)
            Text("Turn this off once every agent signs in through Cloudflare. Tailscale and loopback agents use tokens.")
                .font(.caption2).foregroundStyle(.secondary)
        } else if model.tunnelReady {
            Label("Until step 4 is saved, the public address is protected only by bearer tokens.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func stepRow<Content: View>(_ number: Int, done: Bool, title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout)
                content()
            }
            Spacer()
        }
    }
}
