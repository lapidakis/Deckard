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
            guard let n = Int(total), n > 0 else { return }

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
