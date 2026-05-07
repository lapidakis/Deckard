import Foundation

/// AppleScript sources for Mail.app interactions.
///
/// Convention: scripts emit records separated by `\u{1E}` (Record Separator) and
/// fields separated by `\u{1F}` (Unit Separator). These bytes are exceedingly
/// unlikely to appear in mail content; if they ever do, we lose precision but
/// not safety — `MailAdapter` will skip a malformed row, never crash.
enum MailScripts {

    static let recordSeparator = "\u{1E}"
    static let fieldSeparator = "\u{1F}"

    /// Filter spec used by both `list` and `search` script generation. Text
    /// match is optional; structural filters (mailbox, date range, unread) work
    /// independently.
    ///
    /// `perMailboxCap` bounds how many records a single mailbox contributes,
    /// not a global limit. Final ordering and truncation happens in Swift
    /// after the script returns — necessary for correctness on multi-mailbox
    /// queries (the previous global-break implementation returned old messages
    /// from the first walked mailbox while never seeing newer matches in
    /// later-walked mailboxes).
    struct MessageFilter {
        var account: String = ""
        var mailbox: String = ""
        var textField: MailSearchField = .any
        var textQuery: String = ""
        var sinceISO: String? = nil
        var beforeISO: String? = nil
        var unreadOnly: Bool = false
        var perMailboxCap: Int = 50
    }

    /// Lists every mailbox across every Mail.app account.
    static let listMailboxes: String = """
    set out to ""
    set RS to "\u{1E}"
    set FS to "\u{1F}"
    tell application "Mail"
        repeat with a in accounts
            set acctName to name of a as string
            repeat with mbox in mailboxes of a
                set mboxName to name of mbox as string
                set unreadN to (unread count of mbox) as integer
                set out to out & acctName & FS & mboxName & FS & unreadN & RS
            end repeat
        end repeat
    end tell
    return out
    """

    /// Builds a list/search script. If `filter.textQuery` is empty, no text
    /// match is applied — used by `mail.list_messages`. If non-empty, text
    /// filtering is layered on — used by `mail.search`.
    ///
    /// Date filters use `date received` (closer to user intent — "today's mail"
    /// usually means received today, not sent today).
    static func listMessages(_ filter: MessageFilter) -> String {
        let qEsc = applescriptEscape(filter.textQuery)
        let acctEsc = applescriptEscape(filter.account)
        let mboxEsc = applescriptEscape(filter.mailbox)

        // Build the whose clause: AND-ed conditions, only including those active.
        var conds: [String] = []
        if !filter.textQuery.isEmpty {
            switch filter.textField {
            case .subject: conds.append("(subject contains theQ)")
            case .sender:  conds.append("(sender contains theQ)")
            case .body:    conds.append("(content contains theQ)")
            case .any:     conds.append("(subject contains theQ or sender contains theQ or content contains theQ)")
            }
        }
        if filter.sinceISO != nil { conds.append("(date received ≥ sinceDate)") }
        if filter.beforeISO != nil { conds.append("(date received < beforeDate)") }
        if filter.unreadOnly { conds.append("(read status is false)") }

        let whoseClause = conds.isEmpty ? "messages of mbox" : "messages of mbox whose " + conds.joined(separator: " and ")

        let sinceSetup = filter.sinceISO.flatMap { asDateSetup(varName: "sinceDate", iso: $0) } ?? ""
        let beforeSetup = filter.beforeISO.flatMap { asDateSetup(varName: "beforeDate", iso: $0) } ?? ""

        return """
        set out to ""
        set RS to "\u{1E}"
        set FS to "\u{1F}"
        set theQ to "\(qEsc)"
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set perMboxCap to \(max(1, filter.perMailboxCap))
        \(sinceSetup)
        \(beforeSetup)
        tell application "Mail"
            repeat with a in accounts
                if theAcct = "" or (name of a as string) = theAcct then
                    repeat with mbox in mailboxes of a
                        if theMbox = "" or (name of mbox as string) = theMbox then
                            try
                                set msgs to (\(whoseClause))
                            on error
                                set msgs to {}
                            end try
                            set mboxCount to 0
                            repeat with m in msgs
                                if mboxCount ≥ perMboxCap then exit repeat
                                set msgID to (id of m as string)
                                set msgSubj to (subject of m as string)
                                set msgFrom to (sender of m as string)
                                try
                                    set msgDateSent to ((date sent of m) as «class isot» as string)
                                on error
                                    set msgDateSent to ""
                                end try
                                try
                                    set msgDateRecv to ((date received of m) as «class isot» as string)
                                on error
                                    set msgDateRecv to ""
                                end try
                                try
                                    set msgRead to read status of m
                                on error
                                    set msgRead to false
                                end try
                                set out to out & msgID & FS & (name of a as string) & FS & (name of mbox as string) & FS & msgSubj & FS & msgFrom & FS & msgDateSent & FS & msgDateRecv & FS & (msgRead as string) & RS
                                set mboxCount to mboxCount + 1
                            end repeat
                        end if
                    end repeat
                end if
            end repeat
        end tell
        return out
        """
    }

    /// Gets one message's full content. Mail.app's integer message id is
    /// per-mailbox-unique, NOT globally unique — collisions across accounts and
    /// mailboxes are real, so we always scope the lookup by (id, account, mailbox).
    static func getMessage(account: String, mailbox: String, id: String) -> String {
        let acctEsc = applescriptEscape(account)
        let mboxEsc = applescriptEscape(mailbox)
        let idEsc = applescriptEscape(id)
        return """
        set FS to "\u{1F}"
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set theID to "\(idEsc)"
        tell application "Mail"
            set found to missing value
            repeat with a in accounts
                if (name of a as string) = theAcct then
                    repeat with mbox in mailboxes of a
                        if (name of mbox as string) = theMbox then
                            try
                                set found to (first message of mbox whose id is (theID as integer))
                            end try
                            exit repeat
                        end if
                    end repeat
                    exit repeat
                end if
            end repeat
            if found is missing value then
                error "message_not_found"
            end if
            set msgSubj to (subject of found as string)
            set msgFrom to (sender of found as string)
            try
                set msgDate to ((date sent of found) as «class isot» as string)
            on error
                set msgDate to ""
            end try
            set toRecips to ""
            try
                repeat with r in (to recipients of found)
                    if toRecips = "" then
                        set toRecips to (address of r as string)
                    else
                        set toRecips to toRecips & "," & (address of r as string)
                    end if
                end repeat
            end try
            set msgBody to (content of found as string)
            return theID & FS & theAcct & FS & theMbox & FS & msgSubj & FS & msgFrom & FS & toRecips & FS & msgDate & FS & msgBody
        end tell
        """
    }

    /// Creates a draft and opens it visibly in Mail.app for the user to review,
    /// edit, and send manually. NOT a destructive action — the message stays in
    /// Drafts until the user explicitly sends or deletes it.
    static func createDraft(
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String
    ) -> String {
        let toClause = applescriptListLiteral(to)
        let ccClause = applescriptListLiteral(cc)
        let bccClause = applescriptListLiteral(bcc)
        return """
        set theTo to \(toClause)
        set theCc to \(ccClause)
        set theBcc to \(bccClause)
        set theSubject to "\(applescriptEscape(subject))"
        set theBody to "\(applescriptEscape(body))"
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            tell newMsg
                repeat with addr in theTo
                    make new to recipient at end of to recipients with properties {address:addr}
                end repeat
                repeat with addr in theCc
                    make new cc recipient at end of cc recipients with properties {address:addr}
                end repeat
                repeat with addr in theBcc
                    make new bcc recipient at end of bcc recipients with properties {address:addr}
                end repeat
            end tell
            return "draft"
        end tell
        """
    }

    /// Sends a message. Destructive — the message leaves the Mac when this returns.
    static func sendMessage(
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String
    ) -> String {
        let toClause = applescriptListLiteral(to)
        let ccClause = applescriptListLiteral(cc)
        let bccClause = applescriptListLiteral(bcc)
        return """
        set theTo to \(toClause)
        set theCc to \(ccClause)
        set theBcc to \(bccClause)
        set theSubject to "\(applescriptEscape(subject))"
        set theBody to "\(applescriptEscape(body))"
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:false}
            tell newMsg
                repeat with addr in theTo
                    make new to recipient at end of to recipients with properties {address:addr}
                end repeat
                repeat with addr in theCc
                    make new cc recipient at end of cc recipients with properties {address:addr}
                end repeat
                repeat with addr in theBcc
                    make new bcc recipient at end of bcc recipients with properties {address:addr}
                end repeat
            end tell
            send newMsg
            return "sent"
        end tell
        """
    }

    // MARK: - Helpers

    /// Escape a string for safe inclusion as a double-quoted AppleScript literal.
    /// Handles backslashes and double quotes; control characters that AppleScript
    /// cannot represent inline are stripped to a space. The two delimiter bytes
    /// (0x1E, 0x1F) we use elsewhere are also stripped to keep parsing safe.
    static func applescriptEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":   out += "\\\\"
            case "\"":   out += "\\\""
            case "\u{1E}", "\u{1F}":
                out += " "
            case "\n":   out += "\\n"
            case "\r":   out += "\\r"
            case "\t":   out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += " "
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Builds an AppleScript list literal of escaped strings.
    /// Empty list returns `{}`.
    static func applescriptListLiteral(_ items: [String]) -> String {
        if items.isEmpty { return "{}" }
        let escaped = items.map(applescriptEscape).joined(separator: "\",\"")
        return "{\"\(escaped)\"}"
    }

    /// Emits an AppleScript snippet that constructs a date variable from an ISO
    /// 8601 timestamp. Returns nil for unparseable input — callers should treat
    /// nil as a hard error rather than silently dropping the filter.
    static func asDateSetup(varName: String, iso: String) -> String? {
        let formatter1 = ISO8601DateFormatter()
        formatter1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter1.date(from: iso)
        if date == nil {
            let formatter2 = ISO8601DateFormatter()
            formatter2.formatOptions = [.withInternetDateTime]
            date = formatter2.date(from: iso)
        }
        if date == nil {
            // accept bare yyyy-MM-dd (interpret as midnight UTC)
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "yyyy-MM-dd"
            dayFmt.timeZone = TimeZone(identifier: "UTC")
            date = dayFmt.date(from: iso)
        }
        guard let date else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return """
        set \(varName) to (current date)
        set year of \(varName) to \(comps.year!)
        set month of \(varName) to \(comps.month!)
        set day of \(varName) to \(comps.day!)
        set hours of \(varName) to \(comps.hour ?? 0)
        set minutes of \(varName) to \(comps.minute ?? 0)
        set seconds of \(varName) to \(comps.second ?? 0)
        """
    }
}
