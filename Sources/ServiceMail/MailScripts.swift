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
        var bareDateTz: TimeZone = .current   // tz for parsing bare yyyy-MM-dd inputs
        var unreadOnly: Bool = false
        var perMailboxCap: Int = 50
        /// Seconds the script may spend before it stops walking and returns
        /// what it has. The script must end itself: when Deckard's own
        /// timeout kills osascript, Mail keeps evaluating the request on its
        /// main thread and every later Mail call queues behind it.
        var budgetSeconds: Int = 25
        /// Most message bodies read per mailbox during a body search. Reading
        /// `content` makes Mail render the message's HTML through WebKit.
        var bodyScanCap: Int = 100
        /// With no `since`, body text is searched only this many days back.
        var bodyWindowDays: Int = 30
        /// Only consulted when `mailbox` is empty. An explicit mailbox filter
        /// always wins (explicitly asking for Archive/Junk should work).
        var scope: MailboxScope = .primary
    }

    /// Mailbox names to skip when walking cross-mailbox queries, by scope.
    /// Match is case-insensitive on the AppleScript side.
    static func skipNamesForScope(_ scope: MailboxScope) -> [String] {
        switch scope {
        case .primary:
            return ["Archive", "Deleted Messages", "Trash", "Junk", "Spam"]
        case .withArchive:
            return ["Deleted Messages", "Trash", "Junk", "Spam"]
        case .all:
            return []
        }
    }

    /// AppleScript handler that strips our field/record separators from
    /// message-derived text. Without it a subject containing U+001F/U+001E
    /// shifts fields (forged sender/date in mail.get) or fabricates whole
    /// records with arbitrary ids in mail.list, steering later write calls.
    /// Inside `tell application "Mail"` blocks call it as `my clean(x)`.
    static let cleanHandler = """
    on clean(s)
        set s to s as string
        set oldTID to AppleScript's text item delimiters
        repeat with sep in {character id 30, character id 31}
            set AppleScript's text item delimiters to (sep as string)
            set parts to text items of s
            set AppleScript's text item delimiters to " "
            set s to parts as string
        end repeat
        set AppleScript's text item delimiters to oldTID
        return s
    end clean
    """

    /// Mailbox helpers shared by every script.
    ///
    /// Mail's scripting reports only a mailbox's own name, so two nested
    /// mailboxes called "Utilities" look identical, while Mail's database (and
    /// the fast search path) identifies a mailbox by its full path. Every tool
    /// therefore speaks full paths ("Bills/Utilities"):
    ///   - `mboxPath` builds the path by walking containers up to the account.
    ///   - `findMailbox` resolves a path with Mail's own path-style specifier,
    ///     then falls back to a bare-name match so callers that pass a nested
    ///     mailbox's own name keep working.
    static let mailboxHandlers = """
    on findMailbox(acct, mboxName)
        tell application "Mail"
            try
                set mb to mailbox mboxName of acct
                set probe to name of mb
                return mb
            end try
            repeat with mbRef in mailboxes of acct
                if (name of mbRef as string) = mboxName then return contents of mbRef
            end repeat
        end tell
        return missing value
    end findMailbox

    on mboxPath(mb)
        tell application "Mail"
            set p to (name of mb as string)
            set c to container of mb
            repeat 8 times
                try
                    set upper to container of c
                on error
                    -- c is the account: the path is complete.
                    exit repeat
                end try
                set p to ((name of c) as string) & "/" & p
                set c to upper
            end repeat
        end tell
        return p
    end mboxPath
    """

    /// Account id and name pairs. The id is what Mail's own database uses in
    /// mailbox URLs; the name is what the mail tools show and accept.
    static let listAccounts: String = """
    set out to ""
    set RS to "\u{1E}"
    set FS to "\u{1F}"
    tell application "Mail"
        repeat with a in accounts
            set out to out & (id of a as string) & FS & my clean(name of a as string) & RS
        end repeat
    end tell
    return out
    \(cleanHandler)
    """

    /// Lists every mailbox across every Mail.app account.
    static let listMailboxes: String = """
    set out to ""
    set RS to "\u{1E}"
    set FS to "\u{1F}"
    tell application "Mail"
        repeat with a in accounts
            set acctName to name of a as string
            repeat with mbox in mailboxes of a
                set leafName to name of mbox as string
                set mboxName to my mboxPath(contents of mbox)
                set unreadN to (unread count of mbox) as integer
                -- Mail reports `unread count` as 0 for an account's INBOX
                -- reached through `mailboxes of account`, even when it holds
                -- unread mail (seen on macOS 27 with iCloud; other mailboxes
                -- report correctly). Count the inbox's unread messages
                -- directly. Limited to INBOX because the query is slow on
                -- large mailboxes such as Junk.
                ignoring case
                    set isInbox to (leafName is "INBOX")
                end ignoring
                if isInbox then
                    try
                        set unreadN to count of (messages of mbox whose read status is false)
                    end try
                end if
                set out to out & my clean(acctName) & FS & my clean(mboxName) & FS & unreadN & RS
            end repeat
        end repeat
    end tell
    return out
    \(cleanHandler)
    \(mailboxHandlers)
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

        // Conditions Mail can answer from its message index.
        var structural: [String] = []
        if filter.sinceISO != nil { structural.append("(date received ≥ sinceDate)") }
        if filter.beforeISO != nil { structural.append("(date received < beforeDate)") }
        if filter.unreadOnly { structural.append("(read status is false)") }

        // NEVER put `content` in a `whose` clause. Mail evaluates every term
        // for every message in the mailbox (no short-circuit on the date
        // terms), and `content` renders each message's HTML through WebKit on
        // Mail's main thread. A cross-mailbox "any field" search did that for
        // the whole account, ran past the 60s timeout, and kept Mail busy
        // afterwards so every later request timed out too (2026-11).
        //
        // Instead: phase 1 matches subject/sender in `whose` (index-backed);
        // phase 2 reads bodies one message at a time, only for candidates
        // that pass the structural filter, capped and time-budgeted.
        let hasText = !filter.textQuery.isEmpty
        var headerTerm: String?
        var scanBodies = false
        if hasText {
            switch filter.textField {
            case .subject: headerTerm = "(subject contains theQ)"
            case .sender:  headerTerm = "(sender contains theQ)"
            case .body:    scanBodies = true
            case .any:     headerTerm = "(subject contains theQ or sender contains theQ)"; scanBodies = true
            }
        }

        func whose(_ conds: [String]) -> String {
            conds.isEmpty ? "messages of mbox" : "messages of mbox whose " + conds.joined(separator: " and ")
        }
        let runHeaderPhase = !hasText || headerTerm != nil
        let headerQuery = whose((headerTerm.map { [$0] } ?? []) + structural)
        // Without a lower date bound a body scan would walk the whole
        // mailbox; bound it to a recent window.
        var bodyConds = structural
        if scanBodies && filter.sinceISO == nil { bodyConds.insert("(date received ≥ bodyFloor)", at: 0) }
        let bodyQuery = whose(bodyConds)

        let sinceSetup = filter.sinceISO.flatMap { asDateSetup(varName: "sinceDate", iso: $0, bareDateTz: filter.bareDateTz) } ?? ""
        let beforeSetup = filter.beforeISO.flatMap { asDateSetup(varName: "beforeDate", iso: $0, bareDateTz: filter.bareDateTz) } ?? ""
        let skipList = applescriptListLiteral(skipNamesForScope(filter.scope))

        // Emits one record for message `m`; shared by both phases.
        let emit = """
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
                            set out to out & msgID & FS & my clean(acctName) & FS & my clean(mboxName) & FS & my clean(msgSubj) & FS & my clean(msgFrom) & FS & msgDateSent & FS & msgDateRecv & FS & (msgRead as string) & RS
                            set mboxCount to mboxCount + 1
        """

        // Unfiltered listing: fetch each property for the leading range in
        // one Apple Event (`subject of (messages 1 thru n of mbox)`), not
        // one event per property per message. Per-message gets cost ~25 ms
        // each, which made a cross-mailbox listing exhaust the time budget.
        let unfiltered = !hasText && structural.isEmpty
        let bulkPhase = """
                    try
                        set n to (count of messages of mbox)
                        if n > perMboxCap then set n to perMboxCap
                        if n > 0 then
                            set idList to id of (messages 1 thru n of mbox)
                            set subjList to subject of (messages 1 thru n of mbox)
                            set fromList to sender of (messages 1 thru n of mbox)
                            set sentList to date sent of (messages 1 thru n of mbox)
                            set recvList to date received of (messages 1 thru n of mbox)
                            set readList to read status of (messages 1 thru n of mbox)
                            repeat with i from 1 to n
                                set msgID to ((item i of idList) as string)
                                try
                                    set msgDateSent to ((item i of sentList) as «class isot» as string)
                                on error
                                    set msgDateSent to ""
                                end try
                                try
                                    set msgDateRecv to ((item i of recvList) as «class isot» as string)
                                on error
                                    set msgDateRecv to ""
                                end try
                                set msgRead to false
                                try
                                    set msgRead to ((item i of readList) as boolean)
                                end try
                                set out to out & msgID & FS & my clean(acctName) & FS & my clean(mboxName) & FS & my clean((item i of subjList) as string) & FS & my clean((item i of fromList) as string) & FS & msgDateSent & FS & msgDateRecv & FS & (msgRead as string) & RS
                            end repeat
                        end if
                    end try
        """

        let headerPhase = unfiltered ? bulkPhase : (!runHeaderPhase ? "" : """
                    try
                        set msgs to (\(headerQuery))
                    on error
                        set msgs to {}
                    end try
                    repeat with m in msgs
                        if mboxCount ≥ perMboxCap then exit repeat
                        if ((current date) - startedAt) > budgetSecs then
                            set partialReason to "time"
                            exit repeat
                        end if
                        set msgID to (id of m as string)
                        set end of emittedIDs to msgID
        \(emit)
                    end repeat
        """)

        let bodyPhase = !scanBodies ? "" : """
                    if partialReason is not "time" then
                        try
                            set cands to (\(bodyQuery))
                        on error
                            set cands to {}
                        end try
                        set examined to 0
                        repeat with m in cands
                            if mboxCount ≥ perMboxCap then exit repeat
                            if examined ≥ bodyCap then
                                if partialReason is "" then set partialReason to "bodycap"
                                exit repeat
                            end if
                            if ((current date) - startedAt) > budgetSecs then
                                set partialReason to "time"
                                exit repeat
                            end if
                            set msgID to (id of m as string)
                            if emittedIDs does not contain msgID then
                                set examined to examined + 1
                                set bodyText to ""
                                try
                                    set bodyText to (content of m as string)
                                end try
                                if bodyText contains theQ then
        \(emit)
                                end if
                            end if
                        end repeat
                    end if
        """

        return """
        set out to ""
        set RS to "\u{1E}"
        set FS to "\u{1F}"
        set theQ to "\(qEsc)"
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set skipList to \(skipList)
        set perMboxCap to \(max(1, filter.perMailboxCap))
        set bodyCap to \(max(1, filter.bodyScanCap))
        set budgetSecs to \(max(1, filter.budgetSeconds))
        set startedAt to (current date)
        set bodyFloor to (current date) - (\(max(1, filter.bodyWindowDays)) * days)
        set partialReason to ""
        set skippedCount to 0
        \(sinceSetup)
        \(beforeSetup)
        tell application "Mail"
            -- Collect the mailboxes to walk, inbox first, so the most useful
            -- results are in hand if the time budget runs out.
            set targets to {}
            repeat with a in accounts
                set acctName to (name of a as string)
                if theAcct = "" or acctName = theAcct then
                    repeat with mboxRef in mailboxes of a
                        set mbox to contents of mboxRef
                        set leafName to (name of mbox as string)
                        set mboxName to my mboxPath(mbox)
                        set walkThis to false
                        if theMbox = "" then
                            -- Cross-mailbox: respect scope skip list (case-insensitive).
                            set walkThis to true
                            ignoring case
                                repeat with skipName in skipList
                                    if leafName is (skipName as string) then
                                        set walkThis to false
                                        exit repeat
                                    end if
                                end repeat
                            end ignoring
                        else if mboxName = theMbox or leafName = theMbox then
                            -- Explicit mailbox filter wins regardless of scope.
                            -- A full path names one mailbox; a bare name
                            -- matches every mailbox with that name.
                            set walkThis to true
                        end if
                        if walkThis then
                            set isInbox to false
                            ignoring case
                                set isInbox to (leafName is "INBOX")
                            end ignoring
                            if isInbox then
                                set beginning of targets to {mbox, acctName, mboxName}
                            else
                                set end of targets to {mbox, acctName, mboxName}
                            end if
                        end if
                    end repeat
                end if
            end repeat

            if theMbox is not "" and (count of targets) = 0 then
                return "!nomailbox" & RS
            end if

            repeat with target in targets
                if partialReason is "time" or ((current date) - startedAt) > budgetSecs then
                    set partialReason to "time"
                    set skippedCount to skippedCount + 1
                else
                    set mbox to item 1 of target
                    set acctName to item 2 of target
                    set mboxName to item 3 of target
                    set mboxCount to 0
                    set emittedIDs to {}
        \(headerPhase)
        \(bodyPhase)
                end if
            end repeat
        end tell
        if partialReason is not "" then
            set out to out & "!partial" & FS & partialReason & FS & skippedCount & RS
        end if
        return out
        \(cleanHandler)
        \(mailboxHandlers)
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
                    set mbox to my findMailbox(contents of a, theMbox)
                    if mbox is not missing value then
                        try
                            set found to (first message of mbox whose id is (theID as integer))
                        end try
                    end if
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
            try
                set msgDateRecv to ((date received of found) as «class isot» as string)
            on error
                set msgDateRecv to ""
            end try
            set msgRead to false
            try
                set msgRead to read status of found
            end try
            set msgBody to (content of found as string)
            return theID & FS & theAcct & FS & theMbox & FS & my clean(msgSubj) & FS & my clean(msgFrom) & FS & my clean(toRecips) & FS & msgDate & FS & msgDateRecv & FS & (msgRead as string) & FS & my clean(msgBody)
        end tell
        \(cleanHandler)
        \(mailboxHandlers)
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
    /// 8601 timestamp. Returns nil for unparseable input.
    ///
    /// `bareDateTz` is the timezone used to interpret bare `yyyy-MM-dd` inputs
    /// (no time/zone). Defaults to system-local so "May 6" means what the user
    /// naively expects in their own timezone. Full ISO timestamps with explicit
    /// `Z` or `±HH:MM` offsets are absolute and ignore this parameter.
    ///
    /// Components are then extracted in the SYSTEM timezone (where AppleScript
    /// dates live), so the AppleScript date object represents the same absolute
    /// moment as the input.
    /// Parses the `since`/`before` forms the mail tools accept: a full ISO
    /// 8601 timestamp (with or without fractional seconds), or a bare
    /// `yyyy-MM-dd` meaning midnight in `bareDateTz`.
    static func parseDate(iso: String, bareDateTz: TimeZone = .current) -> Date? {
        let formatter1 = ISO8601DateFormatter()
        formatter1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter1.date(from: iso) { return date }
        let formatter2 = ISO8601DateFormatter()
        formatter2.formatOptions = [.withInternetDateTime]
        if let date = formatter2.date(from: iso) { return date }
        // bare yyyy-MM-dd → midnight in the caller's tz (default: system local)
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = bareDateTz
        return dayFmt.date(from: iso)
    }

    static func asDateSetup(varName: String, iso: String, bareDateTz: TimeZone = .current) -> String? {
        let date = parseDate(iso: iso, bareDateTz: bareDateTz)
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

    /// Batch-move messages from one (account, mailbox) to another mailbox in
    /// one AppleScript invocation. Resolves source/dest mailboxes once, then
    /// collects message references in a loop (capturing per-id resolution
    /// errors), then issues a single `move` against the whole list. Mail.app
    /// batches the IMAP/EWS side itself, so this is one round-trip per
    /// upstream account, regardless of N.
    ///
    /// Output format (one entry per line):
    ///     MATCHED:<int>
    ///     MISSING:<id>           (zero or more, one per id that didn't resolve)
    static func batchMoveMessages(
        account: String, mailbox: String, ids: [String],
        targetAccount: String, targetMailbox: String
    ) -> String {
        let acctEsc = applescriptEscape(account)
        let mboxEsc = applescriptEscape(mailbox)
        let tgtAcctEsc = applescriptEscape(targetAccount)
        let tgtMboxEsc = applescriptEscape(targetMailbox)
        let idsList = appleScriptStringList(ids)
        return """
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set tgtAcct to "\(tgtAcctEsc)"
        set tgtMbox to "\(tgtMboxEsc)"
        set idStrs to \(idsList)
        tell application "Mail"
            set srcMbox to missing value
            repeat with a in accounts
                if (name of a as string) = theAcct then
                    set srcMbox to my findMailbox(contents of a, theMbox)
                    exit repeat
                end if
            end repeat
            if srcMbox is missing value then error "source_mailbox_not_found"

            set destMbox to missing value
            repeat with a in accounts
                if (name of a as string) = tgtAcct then
                    set destMbox to my findMailbox(contents of a, tgtMbox)
                    exit repeat
                end if
            end repeat
            if destMbox is missing value then error "target_mailbox_not_found"

            set msgList to {}
            set okIds to {}
            set missingIds to {}
            repeat with idStr in idStrs
                try
                    set theID to ((idStr as string) as integer)
                    set theMsg to (first message of srcMbox whose id is theID)
                    copy theMsg to end of msgList
                    copy (idStr as string) to end of okIds
                on error
                    copy (idStr as string) to end of missingIds
                end try
            end repeat

            -- Per-msg action loop: Mail.app rejects `move <list>` /
            -- `set <prop> of <list>` with -10006 ("can't set X of {list}"),
            -- so we iterate. AppleScript loop overhead is sub-ms per item;
            -- the dominant cost is osascript startup + Mail.app activation,
            -- which we pay once per call regardless of N.
            set successCount to 0
            set failedIds to {}
            set i to 0
            repeat with msg in msgList
                set i to i + 1
                try
                    move msg to destMbox
                    set successCount to successCount + 1
                on error
                    copy (item i of okIds) to end of failedIds
                end try
            end repeat

            set outputText to "MATCHED:" & successCount
            repeat with mid in missingIds
                set outputText to outputText & linefeed & "MISSING:" & mid
            end repeat
            repeat with fid in failedIds
                set outputText to outputText & linefeed & "FAILED:" & fid
            end repeat
            return outputText
        end tell
        \(mailboxHandlers)
        """
    }

    /// Batch-set read status on multiple messages in one invocation. Same
    /// resolution + collection + per-msg-action pattern as `batchMoveMessages`.
    static func batchSetReadState(
        account: String, mailbox: String, ids: [String], read: Bool
    ) -> String {
        let acctEsc = applescriptEscape(account)
        let mboxEsc = applescriptEscape(mailbox)
        let idsList = appleScriptStringList(ids)
        return """
        set theAcct to "\(acctEsc)"
        set theMbox to "\(mboxEsc)"
        set readVal to \(read ? "true" : "false")
        set idStrs to \(idsList)
        tell application "Mail"
            set srcMbox to missing value
            repeat with a in accounts
                if (name of a as string) = theAcct then
                    set srcMbox to my findMailbox(contents of a, theMbox)
                    exit repeat
                end if
            end repeat
            if srcMbox is missing value then error "source_mailbox_not_found"

            set msgList to {}
            set okIds to {}
            set missingIds to {}
            repeat with idStr in idStrs
                try
                    set theID to ((idStr as string) as integer)
                    set theMsg to (first message of srcMbox whose id is theID)
                    copy theMsg to end of msgList
                    copy (idStr as string) to end of okIds
                on error
                    copy (idStr as string) to end of missingIds
                end try
            end repeat

            set successCount to 0
            set failedIds to {}
            set i to 0
            repeat with msg in msgList
                set i to i + 1
                try
                    set read status of msg to readVal
                    set successCount to successCount + 1
                on error
                    copy (item i of okIds) to end of failedIds
                end try
            end repeat

            set outputText to "MATCHED:" & successCount
            repeat with mid in missingIds
                set outputText to outputText & linefeed & "MISSING:" & mid
            end repeat
            repeat with fid in failedIds
                set outputText to outputText & linefeed & "FAILED:" & fid
            end repeat
            return outputText
        end tell
        \(mailboxHandlers)
        """
    }

    /// Renders a Swift [String] as an AppleScript list literal: ["1","2"] → {"1","2"}.
    /// Empty input becomes the literal `{}` (an empty AppleScript list, which
    /// `count of` returns 0 for and `repeat with x in {}` cleanly skips).
    static func appleScriptStringList(_ items: [String]) -> String {
        if items.isEmpty { return "{}" }
        let joined = items.map { "\"\(applescriptEscape($0))\"" }.joined(separator: ", ")
        return "{\(joined)}"
    }

}
