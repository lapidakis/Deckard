import SwiftUI
import SQLite3

/// Inspects TCC.db for grants made to the Deckard binary. Read-only —
/// changing TCC requires going through System Settings, which we link to.
struct PermissionsTab: View {
    @State private var grants: [Grant] = []
    @State private var loadError: String? = nil

    struct Grant: Identifiable, Hashable {
        let id = UUID()
        let service: String          // "Apple Events → Mail", "Calendar", "Reminders", etc.
        let allowed: Bool
        let lastModified: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OS-level Permissions").font(.title3.bold())
                Spacer()
                Button("Reload") { load() }
            }

            if let err = loadError {
                Text(err).foregroundStyle(.red)
            }

            if grants.isEmpty {
                ContentUnavailableView(
                    "No grants found",
                    systemImage: "hand.raised.slash",
                    description: Text("Make a tool call from your MCP client to trigger the first prompt — or check System Settings → Privacy & Security manually.")
                )
            } else {
                Table(grants) {
                    TableColumn("Service") { Text($0.service) }
                    TableColumn("Granted") { row in
                        Image(systemName: row.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.allowed ? .green : .red)
                    }
                    TableColumn("Last changed") { row in
                        Text(row.lastModified ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Manage").font(.callout.bold())
                Text("Open System Settings to grant or revoke permissions.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Privacy & Security → Automation") {
                        openPrefPane("com.apple.preference.security?Privacy_Automation")
                    }
                    Button("Calendar") {
                        openPrefPane("com.apple.preference.security?Privacy_Calendars")
                    }
                    Button("Reminders") {
                        openPrefPane("com.apple.preference.security?Privacy_Reminders")
                    }
                    Button("Contacts") {
                        openPrefPane("com.apple.preference.security?Privacy_Contacts")
                    }
                    Button("Full Disk Access") {
                        openPrefPane("com.apple.preference.security?Privacy_AllFiles")
                    }
                }
            }
        }
        .padding()
        .task { load() }
    }

    private func openPrefPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func load() {
        let dbPath = NSString("~/Library/Application Support/com.apple.TCC/TCC.db").expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            self.loadError = "TCC.db not readable. Grant the UI Full Disk Access (or check via System Settings)."
            return
        }
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            self.loadError = "Failed to open TCC.db"
            return
        }
        defer { sqlite3_close(db) }

        // Match by binary path (adhoc) OR signing identifier (Developer ID).
        // Carries both the new (deckard) and pre-rename (icloud-bridge)
        // identifiers for one release cycle so users mid-migration still
        // see their existing grants. Drop the legacy clauses in v1.1.
        let sql = """
            SELECT service, client, auth_value, indirect_object_identifier,
                   datetime(last_modified,'unixepoch','localtime')
            FROM access
            WHERE client LIKE '%deckard%'
               OR client = 'com.lapidakis.deckard'
               OR client LIKE '%icloud-bridge%'
               OR client = 'com.lapidakis.icloud-bridge'
            ORDER BY last_modified DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            self.loadError = "TCC.db query failed"
            return
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [Grant] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let service = String(cString: sqlite3_column_text(stmt, 0))
            let auth = sqlite3_column_int(stmt, 2)
            let indirect = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let lastMod = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

            let display: String
            switch service {
            case "kTCCServiceAppleEvents":
                display = indirect.isEmpty ? "Apple Events" : "Apple Events → \(indirect)"
            case "kTCCServiceCalendar":             display = "Calendar"
            case "kTCCServiceReminders":            display = "Reminders"
            case "kTCCServiceContactsFull":         display = "Contacts"
            case "kTCCServiceSystemPolicyAllFiles": display = "Full Disk Access"
            default:                                display = service
            }
            rows.append(Grant(service: display, allowed: auth == 2, lastModified: lastMod))
        }
        self.grants = rows
        self.loadError = nil
    }
}
