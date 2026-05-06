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

    /// Searches a single account+mailbox for messages matching `query` in the
    /// `field` (subject, sender, body, or any). Returns up to `limit` records,
    /// most recent first.
    ///
    /// `account` and `mailbox` may be empty strings to fall through to
    /// "all accounts / all inbox" behavior.
    static func search(
        account: String,
        mailbox: String,
        field: String,        // "subject" | "sender" | "body" | "any"
        query: String,
        limit: Int
    ) -> String {
        let qEsc = applescriptEscape(query)
        let acctEsc = applescriptEscape(account)
        let mboxEsc = applescriptEscape(mailbox)
        let fieldClause: String
        switch field {
        case "subject": fieldClause = "subject contains theQ"
        case "sender":  fieldClause = "(sender contains theQ)"
        case "body":    fieldClause = "(content contains theQ)"
        default:        fieldClause = "(subject contains theQ or sender contains theQ or content contains theQ)"
        }
        return """
        set out to ""
        set RS to "\u{1E}"
        set FS to "\u{1F}"
        set theQ to "\(qEsc)"
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set theLimit to \(max(1, limit))
        set count_taken to 0
        tell application "Mail"
            repeat with a in accounts
                if theAcct = "" or (name of a as string) = theAcct then
                    repeat with mbox in mailboxes of a
                        if theMbox = "" or (name of mbox as string) = theMbox then
                            try
                                set msgs to (messages of mbox whose \(fieldClause))
                            on error
                                set msgs to {}
                            end try
                            repeat with m in msgs
                                if count_taken ≥ theLimit then exit repeat
                                set msgID to (id of m as string)
                                set msgSubj to (subject of m as string)
                                set msgFrom to (sender of m as string)
                                try
                                    set msgDate to ((date sent of m) as «class isot» as string)
                                on error
                                    set msgDate to ""
                                end try
                                try
                                    set msgRead to read status of m
                                on error
                                    set msgRead to false
                                end try
                                set out to out & msgID & FS & (name of a as string) & FS & (name of mbox as string) & FS & msgSubj & FS & msgFrom & FS & msgDate & FS & (msgRead as string) & RS
                                set count_taken to count_taken + 1
                            end repeat
                        end if
                        if count_taken ≥ theLimit then exit repeat
                    end repeat
                end if
                if count_taken ≥ theLimit then exit repeat
            end repeat
        end tell
        return out
        """
    }

    /// Gets one message's full content. Looks the message up by id within the
    /// supplied account+mailbox so we don't accidentally fetch from a wrong
    /// folder if ids collide across accounts.
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

    /// Sends a message. `bcc` may be empty.
    static func sendMessage(
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String
    ) -> String {
        let toList = to.map(applescriptEscape).joined(separator: "\",\"")
        let ccList = cc.map(applescriptEscape).joined(separator: "\",\"")
        let bccList = bcc.map(applescriptEscape).joined(separator: "\",\"")
        let toClause = to.isEmpty ? "{}" : "{\"\(toList)\"}"
        let ccClause = cc.isEmpty ? "{}" : "{\"\(ccList)\"}"
        let bccClause = bcc.isEmpty ? "{}" : "{\"\(bccList)\"}"
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
}
