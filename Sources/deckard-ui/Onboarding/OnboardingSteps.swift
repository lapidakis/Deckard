import SwiftUI
import AppKit
import BridgeAuth

// MARK: - Welcome

struct WelcomeStep: View {
    @ObservedObject var onboarding: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to Deckard")
                .font(.title.bold())
            Text("This Mac is about to become an MCP server that exposes Mail, Calendar, iCloud Drive, Voice Memos, and Reminders to AI agents — local or remote.")
                .foregroundStyle(.secondary)
            Text("This setup walks you through:")
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Confirm the daemon is installed and running")
                bullet("Create a bearer token for your MCP client")
                bullet("Grant macOS permissions for the surfaces you want")
                bullet("Copy the connection details into your client")
            }
            Spacer()
            OnboardingNav(onboarding: onboarding, continueLabel: "Get Started")
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            Text(s)
        }
    }
}

// MARK: - Daemon

struct DaemonStep: View {
    @ObservedObject var status: BridgeStatusModel
    @ObservedObject var onboarding: OnboardingState
    @State private var plistInstalled = OnboardingState.launchAgentInstalled()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daemon").font(.title2.bold())
            Text("The bridge runs as a LaunchAgent in your user session. It needs to be installed once and started at least once.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    statusRow(
                        ok: plistInstalled,
                        label: "LaunchAgent installed",
                        detail: plistInstalled
                            ? OnboardingState.launchAgentPlistPath
                            : "Run `deckard install` from the terminal"
                    )
                    if !plistInstalled {
                        HStack {
                            Text("deckard install")
                                .font(.callout.monospaced())
                                .padding(6)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("deckard install", forType: .string)
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button("Recheck") { plistInstalled = OnboardingState.launchAgentInstalled() }
                        }
                    }

                    Divider()

                    statusRow(
                        ok: status.isRunning,
                        label: "Daemon running",
                        detail: status.isRunning
                            ? "PID \(status.pid.map { "\($0)" } ?? "?") • port \(status.portBound ? "8787 bound" : "not bound")"
                            : "Click Start to bootstrap the LaunchAgent"
                    )
                    if !status.isRunning {
                        HStack {
                            Button("Start daemon") {
                                Task { await status.start() }
                            }
                            Button("Refresh") { Task { await status.refresh() } }
                            Spacer()
                        }
                    }

                    if let err = status.lastError {
                        Text(err).foregroundStyle(.red).font(.caption.monospaced())
                    }
                }
                .padding(8)
            }

            Spacer()
            OnboardingNav(onboarding: onboarding)
        }
        .task { await status.refresh() }
    }
}

// MARK: - Token

struct TokenStep: View {
    @ObservedObject var onboarding: OnboardingState
    @State private var existingTokenCount: Int = OnboardingState.tokenCount()
    @State private var newLabel: String = ""
    @State private var newDescription: String = ""
    @State private var creating: Bool = false
    @State private var createError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bearer Token").font(.title2.bold())
            Text("MCP clients authenticate to the bridge with a bearer token. Each token has a label so the audit log can attribute calls.")
                .foregroundStyle(.secondary)

            if let secret = onboarding.generatedTokenSecret, let label = onboarding.generatedTokenLabel {
                createdTokenBanner(label: label, secret: secret)
            } else if existingTokenCount > 0 {
                existingTokensBanner
            } else {
                createForm
            }

            if let err = createError {
                Text(err).foregroundStyle(.red).font(.callout)
            }

            Spacer()
            OnboardingNav(onboarding: onboarding)
        }
        .task { existingTokenCount = OnboardingState.tokenCount() }
    }

    private var existingTokensBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(existingTokenCount) token\(existingTokenCount == 1 ? "" : "s") already configured")
                        .font(.headline)
                    Text("Use the Settings → Tokens tab (or the `deckard auth` CLI) to view, rotate, or add more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private var createForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Create your first token").font(.headline)
                Form {
                    TextField("Label", text: $newLabel, prompt: Text("e.g. claude-code"))
                    TextField("Description (optional)", text: $newDescription, prompt: Text("e.g. local Claude Code session"))
                }
                .formStyle(.columns)
                HStack {
                    Spacer()
                    Button {
                        Task { await createToken() }
                    } label: {
                        if creating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Create Token")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
        }
    }

    private func createdTokenBanner(label: String, secret: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.tint)
                    Text("Token \"\(label)\" created").font(.headline)
                }
                Text("Copy this now. It won't be shown again — but you can rotate it later from the Tokens tab if you lose it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(secret)
                        .font(.callout.monospaced())
                        .padding(6)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret, forType: .string)
                    }
                }
            }
            .padding(8)
        }
    }

    private func createToken() async {
        creating = true
        defer { creating = false }
        createError = nil
        do {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let entry = try await registry.add(
                label: newLabel.trimmingCharacters(in: .whitespaces),
                profile: nil,
                description: newDescription.trimmingCharacters(in: .whitespaces)
            )
            onboarding.generatedTokenLabel = newLabel.trimmingCharacters(in: .whitespaces)
            onboarding.generatedTokenSecret = entry.secret
            existingTokenCount = OnboardingState.tokenCount()
        } catch {
            createError = "\(error)"
        }
    }
}

// MARK: - Permissions

struct PermissionsStep: View {
    @ObservedObject var onboarding: OnboardingState
    @State private var rows: [OnboardingState.PermissionRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title2.bold())
            Text("macOS asks per-surface for the bridge to read your data. You can grant these now via System Settings, or wait — each will prompt on first use.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        HStack {
                            stateIcon(row.state)
                            Text(row.label).font(.callout)
                            Spacer()
                            if let url = row.prefPaneURL {
                                Button("Open") { openPrefPane(url) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    if rows.isEmpty {
                        Text("Loading TCC state…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            HStack {
                Text("Voice Memos and Drive don't need TCC — Voice Memos lives in a Group Container, Drive uses your normal home directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Recheck") { rows = OnboardingState.permissionRows() }
            }

            Spacer()
            OnboardingNav(onboarding: onboarding)
        }
        .task { rows = OnboardingState.permissionRows() }
    }

    @ViewBuilder
    private func stateIcon(_ state: OnboardingState.PermissionState) -> some View {
        switch state {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:  Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private func openPrefPane(_ id: String) {
        if let url = URL(string: "x-apple.systempreferences:\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Connect

struct ConnectStep: View {
    @ObservedObject var onboarding: OnboardingState

    private let url = "http://127.0.0.1:8787/mcp"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Your Client").font(.title2.bold())
            Text("Use these in your MCP client (Claude Code, Claude Desktop, etc).")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    fieldRow(label: "Server URL", value: url)
                    if let secret = onboarding.generatedTokenSecret {
                        fieldRow(label: "Bearer Token", value: secret, mono: true)
                    } else {
                        fieldRow(
                            label: "Bearer Token",
                            value: "Use a token from the Tokens tab — `deckard auth show <label>` prints the secret.",
                            mono: false
                        )
                    }

                    Divider()

                    Text("Claude Code (terminal)").font(.callout.bold())
                    snippetRow(claudeCodeSnippet)
                }
                .padding(8)
            }

            Spacer()
            OnboardingNav(
                onboarding: onboarding,
                continueLabel: "Finish"
            )
        }
    }

    private var claudeCodeSnippet: String {
        let token = onboarding.generatedTokenSecret ?? "<paste-bearer-token-here>"
        return "claude mcp add --transport http deckard \(url) --header \"Authorization: Bearer \(token)\""
    }

    private func fieldRow(label: String, value: String, mono: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .font(mono ? .callout.monospaced() : .callout)
                    .padding(6)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func snippetRow(_ s: String) -> some View {
        HStack(alignment: .top) {
            Text(s)
                .font(.caption.monospaced())
                .padding(6)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Done

struct DoneStep: View {
    @ObservedObject var onboarding: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)
            Text("You're set up").font(.title.bold())
            Text("The bridge is ready. You can reopen this guide anytime from Settings → Status → Show Onboarding.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                bullet("Settings → Tokens to add or rotate tokens")
                bullet("Settings → ACL to view per-tool decisions")
                bullet("Settings → Permissions to inspect TCC state")
                bullet("Settings → Logs to tail the audit trail")
            }
            .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    onboarding.markCompleted()
                    closeWindow()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private func closeWindow() {
        for w in NSApp.windows where w.identifier?.rawValue == "onboarding" {
            w.performClose(nil)
        }
    }
}

// MARK: - shared row
//
// SwiftUI primitives like `Spacer()` are MainActor-isolated under strict
// Swift 6 concurrency on macOS 15+. Free functions returning `some View`
// must therefore be marked @MainActor, otherwise the call site is
// "synchronous nonisolated" and the build fails on CI even though it
// compiles on macOS 14 dev machines.

@MainActor
private func statusRow(ok: Bool, label: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .font(.title3)
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
    }
}

@MainActor
private func bullet(_ s: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.secondary).padding(.top, 7)
        Text(s)
    }
}
