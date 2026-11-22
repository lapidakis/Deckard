import Foundation
import Logging
import BridgeConfig

/// One-shot startup check of what Spotlight exposes for Mail once the daemon
/// has Full Disk Access.
///
/// It records *shape only*: how many messages Spotlight can see, which
/// metadata attribute names a message carries, and the directory layout of a
/// message file with every name and number masked. No subject, sender,
/// address, body or mailbox name is logged. The Spotlight mail backend is
/// built against this output rather than against assumptions about a store
/// layout Apple changes between releases.
public struct SpotlightProbe: Sendable {
    static let mailQuery = #"kMDItemContentType == "com.apple.mail.emlx""#
    private let logger: Logger

    public init(logger: Logger) { self.logger = logger }

    public func run() async {
        do {
            let count = try await Subprocess.run("/usr/bin/mdfind", arguments: ["-count", Self.mailQuery], timeoutSeconds: 30)
            let total = count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Spotlight probe: mail messages visible=\(total)")
            guard let n = Int(total), n > 0 else {
                await exploreStore()
                return
            }

            // mdfind has no result limit and can list hundreds of thousands
            // of paths; the output cap bounds it and one path is enough.
            let listing: String
            do {
                listing = try await Subprocess.run(
                    "/usr/bin/mdfind", arguments: [Self.mailQuery], timeoutSeconds: 30, maxOutputBytes: 64 * 1024 * 1024).stdout
            } catch {
                logger.info("Spotlight probe: listing too large to sample (\(error))")
                return
            }
            guard let sample = listing.split(separator: "\n").first.map(String.init) else { return }
            logger.info("Spotlight probe: message path shape=\(Self.maskedShape(of: sample))")

            let attributes = try await Subprocess.run("/usr/bin/mdls", arguments: [sample], timeoutSeconds: 20)
            logger.info("Spotlight probe: message attributes=\(Self.attributeNames(mdls: attributes.stdout).joined(separator: ","))")
        } catch {
            logger.warning("Spotlight probe failed: \(error)")
        }
    }

    /// Spotlight showed nothing: describe Mail's on-disk store instead, so the
    /// search backend can be designed for what this macOS version really has.
    /// Structure only: directory names that are not Apple's own are masked,
    /// and for the message database only table and column names are listed.
    private func exploreStore() async {
        let fm = FileManager.default
        let mailDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let top = ((try? fm.contentsOfDirectory(atPath: mailDir.path)) ?? []).sorted()
        logger.info("Mail store probe: top level=\(top.map { Self.maskedShape(of: $0, home: "") }.joined(separator: ","))")
        guard let version = top.filter({ $0.range(of: #"^V\d+$"#, options: .regularExpression) != nil }).last else { return }
        let versionDir = mailDir.appendingPathComponent(version)
        let entries = ((try? fm.contentsOfDirectory(atPath: versionDir.path)) ?? []).sorted()
        logger.info("Mail store probe: \(version) entries=\(entries.map { Self.maskedShape(of: $0, home: "") }.joined(separator: ","))")

        let mailData = versionDir.appendingPathComponent("MailData")
        let dataFiles = ((try? fm.contentsOfDirectory(atPath: mailData.path)) ?? []).sorted()
        logger.info("Mail store probe: MailData files=\(dataFiles.joined(separator: ","))")

        // First message file found by a bounded walk, to learn the layout.
        var emlxCount = 0
        var sample: String?
        if let walker = fm.enumerator(at: versionDir, includingPropertiesForKeys: nil) {
            while let url = walker.nextObject() as? URL {
                if url.pathExtension == "emlx" {
                    emlxCount += 1
                    if sample == nil { sample = url.path }
                    if emlxCount >= 5000 { break }
                }
            }
        }
        logger.info("Mail store probe: emlx files found=\(emlxCount)\(emlxCount >= 5000 ? "+" : "") sample shape=\(sample.map { Self.maskedShape(of: $0) } ?? "none")")
        if let sample, let mdls = try? await Subprocess.run("/usr/bin/mdls", arguments: [sample], timeoutSeconds: 20) {
            logger.info("Mail store probe: sample attributes=\(Self.attributeNames(mdls: mdls.stdout).joined(separator: ","))")
        }

        let index = mailData.appendingPathComponent("Envelope Index").path
        guard fm.fileExists(atPath: index) else { return }
        for (label, sql) in [
            ("tables", "SELECT group_concat(name, ',') FROM sqlite_master WHERE type IN ('table','view') ORDER BY name"),
            ("messages columns", "SELECT group_concat(name, ',') FROM pragma_table_info('messages')"),
            ("mailboxes columns", "SELECT group_concat(name, ',') FROM pragma_table_info('mailboxes')"),
            ("message count", "SELECT count(*) FROM messages"),
            ("fts tables", "SELECT group_concat(name, ',') FROM sqlite_master WHERE sql LIKE '%fts%'"),
        ] {
            if let r = try? await Subprocess.run("/usr/bin/sqlite3", arguments: ["-readonly", "file:\(index)?mode=ro", sql], timeoutSeconds: 20) {
                let out = r.exitCode == 0 ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "error: " + r.stderr.prefix(120)
                logger.info("Mail store probe: index \(label)=\(out)")
            }
        }
    }

    /// `/Users/me/Library/Mail/V10/1A2B…/Work.mbox/…/Messages/831686.emlx`
    /// becomes `~/Library/Mail/V10/<uuid>/<name>.mbox/…/Messages/<n>.emlx`.
    static func maskedShape(of path: String, home: String = NSHomeDirectory()) -> String {
        let relative = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let structural: Set<String> = ["~", "Library", "Mail", "Data", "Messages", "Attachments"]
        return relative.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let s = String(part)
            if structural.contains(s) || s.isEmpty { return s }
            if s.range(of: #"^V\d+$"#, options: .regularExpression) != nil { return s }
            if s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil { return "<uuid>" }
            if s.range(of: #"^\d+$"#, options: .regularExpression) != nil { return "<n>" }
            if let dot = s.lastIndex(of: "."), s[s.index(after: dot)...].allSatisfy({ $0.isLetter }) {
                let stem = s[..<dot]
                let masked = stem.allSatisfy(\.isNumber) ? "<n>" : (stem.contains(".") ? "<n>.<part>" : "<name>")
                return masked + s[dot...]
            }
            return "<name>"
        }.joined(separator: "/")
    }

    /// Attribute names from `mdls` output (`kMDItemSubject = "…"`), no values.
    static func attributeNames(mdls: String) -> [String] {
        var names: [String] = []
        for line in mdls.split(separator: "\n") {
            guard let first = line.first, first.isLetter || first == "_",
                  let equals = line.range(of: " = ") ?? line.range(of: "=") else { continue }
            let name = line[..<equals.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" ") { names.append(name) }
        }
        return names.sorted()
    }
}
