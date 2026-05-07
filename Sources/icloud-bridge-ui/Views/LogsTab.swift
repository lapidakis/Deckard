import SwiftUI

/// Tails the audit JSONL. Refreshes on a timer when this tab is visible.
struct LogsTab: View {
    @State private var lines: [Line] = []
    @State private var loadError: String? = nil
    @State private var pollTask: Task<Void, Never>? = nil
    @State private var maxLines: Int = 100

    struct Line: Identifiable, Hashable {
        let id = UUID()
        let raw: String
        let ts: String?
        let tool: String?
        let caller: String?
        let decision: String?
        let latencyMs: Int?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audit Log").font(.title3.bold())
                Spacer()
                Stepper("Tail \(maxLines)", value: $maxLines, in: 25...500, step: 25)
                Button("Refresh") { load() }
            }

            if let err = loadError {
                Text(err).foregroundStyle(.red)
            }

            Table(lines) {
                TableColumn("Time") { Text($0.ts ?? "—").font(.caption.monospacedDigit()) }
                    .width(min: 180, ideal: 200)
                TableColumn("Caller") { Text($0.caller ?? "—").font(.caption) }
                    .width(min: 100, ideal: 130)
                TableColumn("Tool") { Text($0.tool ?? "—").font(.caption) }
                    .width(min: 140, ideal: 180)
                TableColumn("Decision") { row in
                    Text(row.decision ?? "—")
                        .font(.caption.bold())
                        .foregroundStyle(decisionColor(row.decision ?? ""))
                }
                .width(min: 70, ideal: 80)
                TableColumn("ms") { Text($0.latencyMs.map { "\($0)" } ?? "—").font(.caption.monospacedDigit()) }
                    .width(min: 50, ideal: 60)
            }
        }
        .padding()
        .onAppear {
            load()
            pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    load()
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private func decisionColor(_ s: String) -> Color {
        switch s {
        case "allow":     return .green
        case "deny":      return .red
        case "error":     return .orange
        case "approved":  return .green
        case "denied":    return .red
        default:          return .secondary
        }
    }

    private func load() {
        let auditPath = NSString("~/Library/Logs/iCloud-Bridge/audit.jsonl").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: auditPath) else {
            self.lines = []
            self.loadError = nil
            return
        }
        do {
            let text = try String(contentsOfFile: auditPath, encoding: .utf8)
            let nonEmpty = text.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = nonEmpty.suffix(maxLines)
            self.lines = tail.reversed().map { line in
                let raw = String(line)
                return Line(
                    raw: raw,
                    ts: extract(raw, "ts"),
                    tool: extract(raw, "tool"),
                    caller: extract(raw, "caller"),
                    decision: extract(raw, "decision"),
                    latencyMs: Int(extract(raw, "latency_ms") ?? "")
                )
            }
            self.loadError = nil
        } catch {
            self.loadError = "Failed to read audit log: \(error)"
        }
    }

    /// Cheap field extraction — JSON-aware enough for our flat audit format.
    private func extract(_ line: String, _ key: String) -> String? {
        let needle = "\"\(key)\":"
        guard let r = line.range(of: needle) else { return nil }
        let after = line[r.upperBound...]
        if after.hasPrefix("\"") {
            let inner = after.dropFirst()
            guard let end = inner.firstIndex(of: "\"") else { return nil }
            return String(inner[..<end])
        }
        // numeric value
        let chars = "0123456789"
        let digitChars = CharacterSet(charactersIn: chars)
        var captured = ""
        for ch in after {
            if digitChars.contains(ch.unicodeScalars.first!) || (captured.isEmpty && ch == "-") {
                captured.append(ch)
            } else {
                break
            }
        }
        return captured.isEmpty ? nil : captured
    }
}
