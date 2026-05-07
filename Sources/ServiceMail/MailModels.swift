import Foundation

public enum MailSearchField: String, Sendable {
    case subject, sender, body, any
}

/// Which mailboxes a cross-mailbox query (mailbox="") should walk.
///
/// Default `primary` skips Archive, Deleted Messages / Trash, and Junk / Spam
/// — the folders that are large, mostly-cold, and rarely what an agent doing
/// "find recent mail from X" actually wants. Opt in to include them when the
/// query is genuinely historical or compliance-oriented.
///
/// An explicit `mailbox` filter on the call always wins over `scope` — the
/// caller can still ask for `mailbox="Archive"` or `mailbox="Junk"` directly.
public enum MailboxScope: String, Sendable {
    /// Skip Archive, Trash/Deleted Messages, Junk/Spam. Default.
    case primary
    /// Include Archive; still skip Trash and Junk.
    case withArchive = "with_archive"
    /// Walk every mailbox, including Trash and Junk.
    case all
}

public struct MailboxRef: Codable, Sendable, Hashable {
    public let account: String
    public let name: String
    public let unreadCount: Int?
    public init(account: String, name: String, unreadCount: Int? = nil) {
        self.account = account
        self.name = name
        self.unreadCount = unreadCount
    }
    enum CodingKeys: String, CodingKey {
        case account, name
        case unreadCount = "unread_count"
    }
}

public struct MessageSummary: Codable, Sendable, Hashable {
    public let id: String              // Mail.app message id (numeric, scoped to account+mailbox)
    public let account: String
    public let mailbox: String
    public let subject: String
    public let sender: String
    public let dateSent: String?       // ISO 8601
    public let dateReceived: String?   // ISO 8601 — what filters use
    public let isRead: Bool
    public init(
        id: String, account: String, mailbox: String,
        subject: String, sender: String,
        dateSent: String?, dateReceived: String?,
        isRead: Bool
    ) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.subject = subject
        self.sender = sender
        self.dateSent = dateSent
        self.dateReceived = dateReceived
        self.isRead = isRead
    }
    enum CodingKeys: String, CodingKey {
        case id, account, mailbox, subject, sender
        case dateSent = "date_sent"
        case dateReceived = "date_received"
        case isRead = "is_read"
    }
}

public struct Message: Codable, Sendable {
    public let id: String
    public let account: String
    public let mailbox: String
    public let subject: String
    public let sender: String
    public let recipients: [String]
    public let dateSent: String?
    public let body: String
    public init(
        id: String, account: String, mailbox: String,
        subject: String, sender: String, recipients: [String],
        dateSent: String?, body: String
    ) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.dateSent = dateSent
        self.body = body
    }
    enum CodingKeys: String, CodingKey {
        case id, account, mailbox, subject, sender, recipients, body
        case dateSent = "date_sent"
    }
}
