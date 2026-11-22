import Foundation

/// Extracts searchable text from a Mail `.emlx` file.
///
/// An `.emlx` is a byte count on the first line, then that many bytes of a
/// raw RFC 5322 message, then a property list Mail appends. The message text
/// is rarely readable as-is: parts are base64 or quoted-printable encoded and
/// nested in MIME multiparts, so a plain substring search over the file would
/// miss most matches. This decodes the text parts (plain and HTML) and
/// ignores attachments.
///
/// It is a search aid, not a renderer: it does not need to be a complete MIME
/// implementation, only to recover the words. Anything it cannot decode is
/// skipped.
enum EmlxText {
    /// Stops runaway nesting in a malformed or hostile message.
    static let maxDepth = 8

    static func searchableText(emlx: Data) -> String? {
        guard let message = messageBytes(emlx: emlx) else { return nil }
        var out = ""
        collectText(part: message, depth: 0, into: &out)
        return out
    }

    /// The raw message: the bytes after the first line, limited to the count
    /// that line declares.
    static func messageBytes(emlx: Data) -> Data? {
        guard let newline = emlx.firstIndex(of: 0x0A),
              let countText = String(data: emlx[emlx.startIndex..<newline], encoding: .ascii),
              let count = Int(countText.trimmingCharacters(in: .whitespaces)), count >= 0 else { return nil }
        let start = emlx.index(after: newline)
        let end = min(emlx.endIndex, emlx.index(start, offsetBy: count, limitedBy: emlx.endIndex) ?? emlx.endIndex)
        return emlx[start..<end]
    }

    private static func collectText(part: Data, depth: Int, into out: inout String) {
        guard depth <= maxDepth else { return }
        let (headers, body) = splitHeaders(part)
        let contentType = headers["content-type"] ?? "text/plain"
        let mediaType = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? "text/plain"

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType) else { return }
            for child in splitMultipart(body, boundary: boundary) {
                collectText(part: child, depth: depth + 1, into: &out)
            }
            return
        }
        if mediaType == "message/rfc822" {
            collectText(part: body, depth: depth + 1, into: &out)
            return
        }
        guard mediaType.hasPrefix("text/") else { return }
        // A text part marked as an attachment is a file, not message text.
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return }

        let decoded = decodeTransfer(body, encoding: headers["content-transfer-encoding"] ?? "7bit")
        guard var text = string(decoded, charset: parameter("charset", in: contentType)) else { return }
        if mediaType == "text/html" { text = stripHTML(text) }
        out += text
        out += "\n"
    }

    /// Splits a part into lowercased header fields and its body.
    static func splitHeaders(_ part: Data) -> ([String: String], Data) {
        // Headers end at the first blank line (CRLF CRLF or LF LF).
        var headerEnd = part.endIndex
        var bodyStart = part.endIndex
        var i = part.startIndex
        while i < part.endIndex {
            if part[i] == 0x0A {
                let next = part.index(after: i)
                if next < part.endIndex, part[next] == 0x0A {
                    headerEnd = i; bodyStart = part.index(after: next); break
                }
                if next < part.endIndex, part[next] == 0x0D,
                   part.index(after: next) < part.endIndex, part[part.index(after: next)] == 0x0A {
                    headerEnd = i; bodyStart = part.index(next, offsetBy: 2); break
                }
            }
            i = part.index(after: i)
        }
        // Normalize line endings first: in Swift "\r\n" is one Character, so
        // splitting CRLF text on "\n" finds nothing.
        let headerText = String(decoding: part[part.startIndex..<headerEnd], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var headers: [String: String] = [:]
        var current: String?
        for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            // The header block ends just before the final LF, so its last
            // line can still carry a lone CR.
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if let first = line.first, first == " " || first == "\t", let key = current {
                // Folded continuation of the previous field.
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        return (headers, part[bodyStart..<part.endIndex])
    }

    /// `name=value` or `name="value"` from a header such as Content-Type.
    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].lowercased() == name else { continue }
            var value = String(trimmed[trimmed.index(after: equals)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var searchFrom = body.startIndex
        var partStart: Data.Index?
        while let range = body.range(of: delimiter, in: searchFrom..<body.endIndex) {
            if let start = partStart, start <= range.lowerBound {
                parts.append(body[start..<range.lowerBound])
            }
            // "--boundary--" closes the multipart.
            let after = range.upperBound
            if body[after...].starts(with: Data("--".utf8)) { return parts }
            // The part begins after the delimiter line.
            if let lineEnd = body[after...].firstIndex(of: 0x0A) {
                partStart = body.index(after: lineEnd)
            } else {
                return parts
            }
            searchFrom = range.upperBound
        }
        if let start = partStart, start < body.endIndex { parts.append(body[start..<body.endIndex]) }
        return parts
    }

    static func decodeTransfer(_ body: Data, encoding: String) -> Data {
        switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        var out = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x3D { // "="
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }                      // soft break LF
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue } // soft break CRLF
                if i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                    out.append(high << 4 | low); i += 3; continue
                }
            }
            out.append(byte)
            i += 1
        }
        return out
    }

    static func string(_ data: Data, charset: String?) -> String? {
        let name = (charset ?? "utf-8").lowercased()
        let encoding: String.Encoding
        switch name {
        case "utf-8", "utf8", "us-ascii", "ascii": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            encoding = cf == kCFStringEncodingInvalidId
                ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        // Mislabelled charsets are common; never drop the text over it.
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// Drops tags, scripts and styles and decodes the commonest entities.
    /// Enough to make the visible words searchable.
    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style|head)\\b.*?</\\1>", "(?s)<!--.*?-->", "(?s)<[^>]*>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
    }
}
