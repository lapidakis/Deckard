import Foundation
import SwiftUI
import SQLite3
import BridgeAuth
import BridgeConfig

/// Drives the first-launch onboarding flow. Tracks completion state in
/// `UserDefaults` and exposes file-system probes the step views use to
/// decide whether they're already done.
///
/// Two ways the window opens:
/// - Auto: cold-launch trigger via `OnboardingLauncher` if `completedAt` is
///   unset (and the user hasn't explicitly skipped).
/// - Manual: "Show Onboarding…" button in the Status tab — `forceOpen()`
///   resets `currentStep` to .welcome but leaves completedAt alone so the
///   auto-open suppression continues to hold.
@MainActor
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case daemon
        case token
        case permissions
        case connect
        case done

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome:     return "Welcome"
            case .daemon:      return "Daemon"
            case .token:       return "Token"
            case .permissions: return "Permissions"
            case .connect:     return "Connect"
            case .done:        return "Done"
            }
        }
    }

    // MARK: - Persisted flags

    private static let completedAtKey = "onboarding.completedAtISO"
    private static let skippedAtKey   = "onboarding.skippedAtISO"
    private static let lastStepKey    = "onboarding.lastStepRaw"

    @Published var currentStep: Step
    @Published var generatedTokenSecret: String? = nil  // Plaintext shown ONCE
    @Published var generatedTokenLabel: String? = nil

    init() {
        let raw = UserDefaults.standard.integer(forKey: Self.lastStepKey)
        self.currentStep = Step(rawValue: raw) ?? .welcome
    }

    // MARK: - Auto-open decision

    /// True when the cold-launch trigger should open the window.
    /// Returns false once the user has either completed or explicitly skipped.
    static func shouldAutoOpenAtLaunch() -> Bool {
        let d = UserDefaults.standard
        if d.string(forKey: completedAtKey) != nil { return false }
        if d.string(forKey: skippedAtKey)   != nil { return false }
        return true
    }

    /// User finished — don't auto-open again.
    func markCompleted() {
        UserDefaults.standard.set(Self.nowISO(), forKey: Self.completedAtKey)
        UserDefaults.standard.set(currentStep.rawValue, forKey: Self.lastStepKey)
    }

    /// User clicked "Skip" — same suppression effect as completion, but a
    /// distinct timestamp so we can later show "Resume onboarding" hints.
    func markSkipped() {
        UserDefaults.standard.set(Self.nowISO(), forKey: Self.skippedAtKey)
        UserDefaults.standard.set(currentStep.rawValue, forKey: Self.lastStepKey)
    }

    /// "Show onboarding" button in Settings re-opens at step 1 without
    /// clearing completedAt — the auto-open suppression stays in effect.
    func forceOpen() {
        currentStep = .welcome
    }

    // MARK: - Navigation

    func goNext() {
        let i = currentStep.rawValue
        if let next = Step(rawValue: i + 1) {
            currentStep = next
            UserDefaults.standard.set(next.rawValue, forKey: Self.lastStepKey)
        }
    }

    func goBack() {
        let i = currentStep.rawValue
        if let prev = Step(rawValue: i - 1) {
            currentStep = prev
            UserDefaults.standard.set(prev.rawValue, forKey: Self.lastStepKey)
        }
    }

    func goTo(_ step: Step) {
        currentStep = step
        UserDefaults.standard.set(step.rawValue, forKey: Self.lastStepKey)
    }

    // MARK: - System probes used by step views

    static var configFilePath: String {
        NSString("~/Library/Application Support/iCloud-Bridge/config.toml").expandingTildeInPath
    }

    static var tokensFilePath: String {
        NSString("~/Library/Application Support/iCloud-Bridge/tokens.toml").expandingTildeInPath
    }

    static var launchAgentPlistPath: String {
        NSString("~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist").expandingTildeInPath
    }

    /// Counts entries in `tokens.toml` without parsing TOML — looks for
    /// `[tokens.<label>]` table headers. Robust enough for "do you have any
    /// tokens at all?" which is all the onboarding step needs.
    static func tokenCount() -> Int {
        guard let text = try? String(contentsOfFile: tokensFilePath, encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n").reduce(0) { acc, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[tokens.") ? acc + 1 : acc
        }
    }

    static func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }

    /// Required TCC services the agent will use. Each is reported with its
    /// granted/denied/unknown state. Read-only — the UI links to System
    /// Settings for changes.
    enum PermissionState: String { case granted, denied, unknown }

    struct PermissionRow: Identifiable {
        let id = UUID()
        let label: String
        let state: PermissionState
        let prefPaneURL: String?  // x-apple.systempreferences:... deep link
    }

    static func permissionRows() -> [PermissionRow] {
        // (display label, kTCC service, optional indirect identifier, pref pane id)
        let probes: [(String, String, String?, String?)] = [
            ("Calendar",                "kTCCServiceCalendar",   nil,                      "com.apple.preference.security?Privacy_Calendars"),
            ("Reminders",               "kTCCServiceReminders",  nil,                      "com.apple.preference.security?Privacy_Reminders"),
            ("Apple Events → Mail",     "kTCCServiceAppleEvents", "com.apple.mail",        "com.apple.preference.security?Privacy_Automation"),
            ("Apple Events → System Events", "kTCCServiceAppleEvents", "com.apple.systemevents", "com.apple.preference.security?Privacy_Automation"),
        ]

        let dbPath = NSString("~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            // Without TCC.db read access, we can't tell — "unknown" so the
            // UI nudges the user to look in System Settings rather than
            // misclassifying a granted permission as missing.
            return probes.map { PermissionRow(label: $0.0, state: .unknown, prefPaneURL: $0.3) }
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return probes.map { PermissionRow(label: $0.0, state: .unknown, prefPaneURL: $0.3) }
        }

        return probes.map { (label, service, indirect, pref) in
            let state = queryAuth(db: db, service: service, indirect: indirect)
            return PermissionRow(label: label, state: state, prefPaneURL: pref)
        }
    }

    private static func queryAuth(db: OpaquePointer?, service: String, indirect: String?) -> PermissionState {
        let sql: String
        if indirect != nil {
            sql = "SELECT auth_value FROM access WHERE service=? AND indirect_object_identifier=? AND (client LIKE '%icloud-bridge%' OR client='com.lapidakis.icloud-bridge') ORDER BY last_modified DESC LIMIT 1"
        } else {
            sql = "SELECT auth_value FROM access WHERE service=? AND (client LIKE '%icloud-bridge%' OR client='com.lapidakis.icloud-bridge') ORDER BY last_modified DESC LIMIT 1"
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unknown
        }
        sqlite3_bind_text(stmt, 1, (service as NSString).utf8String, -1, nil)
        if let indirect = indirect {
            sqlite3_bind_text(stmt, 2, (indirect as NSString).utf8String, -1, nil)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return .unknown    // No row → never prompted yet
        }
        // auth_value: 0 = denied, 2 = allowed, 3 = limited
        return sqlite3_column_int(stmt, 0) == 2 ? .granted : .denied
    }

    private static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
